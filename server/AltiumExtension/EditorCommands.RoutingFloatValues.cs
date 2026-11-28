using System.Globalization;
using System.IO;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private sealed record RoutingFloatValues(byte[] Contents, Dictionary<RoutingFloatKey, string> Values)
    {
        internal const string FileName = "routing-float-values.tsv";
        private const string Header = "value\ttext";

        internal static RoutingFloatValues Read(string directory)
        {
            byte[] contents = File.ReadAllBytes(Path.Combine(directory, "baseline-" + FileName));
            using var reader = new StreamReader(new MemoryStream(contents, writable: false), RoutingUtf8);
            if (reader.ReadLine() != Header)
                throw new CommandUnavailable("The staged PCB floating-point values have an invalid header");

            var values = new Dictionary<RoutingFloatKey, string>();
            while (reader.ReadLine() is { } line)
            {
                string[] fields = line.Split('\t');
                if (fields.Length != 2 || !RoutingFloatKey.TryParse(fields[0], out var key) ||
                    fields[1] != fields[1].Trim() ||
                    !double.TryParse(fields[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double number) ||
                    !double.IsFinite(number) || !values.TryAdd(key, fields[1]))
                    throw new CommandUnavailable("The staged PCB floating-point values are malformed");
            }
            return new RoutingFloatValues(contents, values);
        }

        internal string Format(double value)
        {
            if (double.IsFinite(value) && Values.TryGetValue(RoutingFloatKey.FromDouble(value), out string? text))
                return text;
            throw new MissingRoutingFloatValue();
        }

        internal void CopyTo(string directory) => File.WriteAllBytes(Path.Combine(directory, FileName), Contents);
    }

    private sealed class MissingRoutingFloatValue() : Exception("A PCB floating-point value differs from the baseline inventory");

    private readonly record struct RoutingFloatKey(int High, int Low, int Exponent)
    {
        private const int LowBits = 24;
        private const int LowMask = (1 << LowBits) - 1;
        private const int MinHigh = 1 << (52 - LowBits);
        private const int MaxHigh = 2 * MinHigh - 1;

        internal static RoutingFloatKey FromDouble(double value)
        {
            if (value == 0)
                return default;
            int exponent = Math.ILogB(value);
            // Scaling by a power of two is exact, including for subnormal values.
            long mantissa = (long)(Math.ScaleB(Math.Abs(value), -exponent) * (1L << 52));
            int high = (int)(mantissa >> LowBits);
            return new RoutingFloatKey(value < 0 ? -high : high, (int)(mantissa & LowMask), exponent);
        }

        internal static bool TryParse(string text, out RoutingFloatKey key)
        {
            key = default;
            string[] fields = text.Split(',');
            if (fields.Length != 3 ||
                !int.TryParse(fields[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int high) ||
                !int.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out int low) ||
                !int.TryParse(fields[2], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int exponent))
                return false;
            if (high == 0)
                return low == 0 && exponent == 0;
            if (high is < -MaxHigh or > MaxHigh || high is > -MinHigh and < MinHigh ||
                low is < 0 or > LowMask || exponent is < -1074 or > 1023)
                return false;
            key = new RoutingFloatKey(high, low, exponent);
            return true;
        }
    }
}
