[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AltiumExe,
    [ValidateSet('Build', 'Install', 'Uninstall')]
    [string]$Action = 'Build',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$altium = Get-Item -LiteralPath $AltiumExe
if ($altium.Name -ine 'X2.EXE') {
    throw 'AltiumExe must be the full path to an Altium Designer X2.EXE.'
}

$name = 'AltiumMcpSdk'
$extensionId = '48E45320-23BA-4753-A0EA-8C678777A8D7'
$installFiles = @("$name.dll", "$name.deps.json", "$name.ins", "$name.rcs")
$version = $altium.VersionInfo.ProductVersion
if ($version -notmatch '^\d+(\.\d+)+$') {
    throw 'Could not determine the target Altium build.'
}
$artifacts = Join-Path $repository "generated/altium-mcp-sdk/$version"
$output = Join-Path $artifacts 'release'

if ($SkipBuild -and $Action -ne 'Install') {
    throw 'SkipBuild is available only with Install.'
}
if ($Action -ne 'Uninstall' -and !$SkipBuild) {
    $runtime = Get-Content -Raw -LiteralPath (Join-Path $altium.DirectoryName 'X2.runtimeconfig.json') |
        ConvertFrom-Json
    $framework = $runtime.runtimeOptions.tfm
    if ($framework -notin @('net8.0', 'net10.0')) {
        throw "Unsupported hosted runtime $framework."
    }
    $source = Join-Path $repository "server/AltiumExtension/$name.csproj"
    $build = @('build', $source, '--configuration', 'Release', '--output', $output,
        '--artifacts-path', (Join-Path $artifacts 'build'),
        "-p:AltiumSystemDir=$(Join-Path $altium.DirectoryName 'System')",
        "-p:AltiumTargetFramework=$framework-windows")
    & dotnet @build
    if ($LASTEXITCODE) {
        throw "The Altium MCP SDK extension build failed with exit code $LASTEXITCODE."
    }
}
if ($Action -ne 'Uninstall') {
    foreach ($file in $installFiles) {
        Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output $file)
    }
}
if ($Action -eq 'Build') { return }

$running = Get-Process -Name X2 -ErrorAction SilentlyContinue
if ($running | Where-Object { !$_.Path -or $_.Path -ieq $altium.FullName }) {
    throw 'Close the target Altium Designer installation before modifying its extensions.'
}

$buildEntries = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Altium\Builds\*' |
    Where-Object { $_.ProgramsInstallPath -and
        [System.IO.Path]::GetFullPath((Join-Path $_.ProgramsInstallPath 'X2.EXE')) -ieq $altium.FullName })
if ($buildEntries.Count -ne 1 -or !$buildEntries[0].Application) {
    throw 'Could not resolve a unique Altium data directory from the installer registry.'
}
$programData = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
$extensionRoot = [System.IO.Path]::GetFullPath((Join-Path $programData "$($buildEntries[0].Application)/Extensions"))
if (!$extensionRoot.StartsWith("$programData\Altium\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "The resolved extensions directory is outside ProgramData\Altium."
}
$destination = Join-Path $extensionRoot $name
if ((Test-Path -LiteralPath $destination) -and
    ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'The extension destination is a junction or symbolic link.'
}

$registry = Join-Path $extensionRoot 'ExtensionsRegistry.xml'
$xml = [System.Xml.XmlDocument]::new()
$xml.PreserveWhitespace = $true
$xml.Load($registry)
if ($xml.DocumentElement.Name -cne 'Extensions') {
    throw 'Unexpected Altium extensions registry format.'
}
$entries = @($xml.SelectNodes('/Extensions/Item') |
    Where-Object { $_.GetAttribute('HRID') -ieq $name -or $_.GetAttribute('Guid') -ieq $extensionId })
if ($entries.Count -gt 1 -or ($entries.Count -eq 1 -and
    ($entries[0].GetAttribute('HRID') -ine $name -or
        $entries[0].GetAttribute('Guid') -ine $extensionId -or
        $entries[0].SelectSingleNode('Path').InnerText -ine $destination))) {
    throw 'The existing extension registration conflicts with this extension.'
}
$entry = $entries | Select-Object -First 1
$ownerMarker = Join-Path $destination '.altium-mcp-sdk'
$owned = (Test-Path -LiteralPath $ownerMarker -PathType Leaf) -and
    ([IO.File]::ReadAllText($ownerMarker) -ceq $extensionId)
if ($Action -eq 'Uninstall' -and !$entry -and !$owned) { return }
if ($Action -eq 'Install' -and !$entry -and !$owned -and (Test-Path -LiteralPath $destination)) {
    throw 'The destination already exists without the matching extension registration.'
}
foreach ($path in @($registry, $ownerMarker) + @($installFiles | ForEach-Object { Join-Path $destination $_ })) {
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Expected an ordinary file at $path."
        }
    }
}

New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$backup = Join-Path $artifacts ("ExtensionsRegistry-before-{0}-{1}.xml" -f $Action, [Guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $registry -Destination $backup

if ($Action -eq 'Install') {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    [IO.File]::WriteAllText($ownerMarker, $extensionId)
    foreach ($file in $installFiles) {
        Copy-Item -LiteralPath (Join-Path $output $file) -Destination (Join-Path $destination $file) -Force
    }
    if (!$entry) {
        $entry = $xml.CreateElement('Item')
        $entry.SetAttribute('HRID', $name)
        $entry.SetAttribute('Guid', $extensionId)
        $entry.InnerXml = @'
<Path/><Status>0</Status><VaultGuid/><CreatedBy/><CategoryGuid>793A1F67-0B22-4E01-A5DE-3176A1E8C60D</CategoryGuid><CategoryName/><ReadMe/><Help/><Requirements/><Title/><ShortDescription/><LongDescription/><SmallImage/><LargeImage/><Version/><VersionGuid/><ReleasedDate>0</ReleasedDate><ReleaseNotes/><DateInstalled>0</DateInstalled><PlatformVersions><DXP BuildNumber="1.0.6.0"/><EDP BuildNumber="10.0.6.0"/><MaxDXP BuildNumber="0.0.0.0"/><MaxEDP BuildNumber="0.0.0.0"/></PlatformVersions>
'@
        $entry.SelectSingleNode('Path').InnerText = $destination
        $xml.DocumentElement.AppendChild($entry) | Out-Null
    }
    $entry.SelectSingleNode('Title').InnerText = $name
    $entry.SelectSingleNode('CreatedBy').InnerText = 'Altium MCP contributors'
    $entry.SelectSingleNode('Version').InnerText = ''
} elseif ($entry) {
    $xml.DocumentElement.RemoveChild($entry) | Out-Null
}

$temporary = Join-Path $extensionRoot ("{0}-{1}.tmp" -f $name, [Guid]::NewGuid().ToString('N'))
try {
    # Altium's extension registry loader expects UTF-8 without a byte-order mark.
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.Xml.XmlWriter]::Create($temporary, $settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    [System.IO.File]::Replace($temporary, $registry, [NullString]::Value)
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

if ($Action -eq 'Uninstall') {
    foreach ($file in $installFiles) {
        $path = Join-Path $destination $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $ownerMarker) { Remove-Item -LiteralPath $ownerMarker -Force }
    if ((Test-Path -LiteralPath $destination) -and !(Get-ChildItem -LiteralPath $destination -Force)) {
        Remove-Item -LiteralPath $destination
    }
}
[pscustomobject]@{
    Action = $Action
    Altium = $altium.FullName
    Version = $version
    Extension = $destination
    RegistryBackup = $backup
}
