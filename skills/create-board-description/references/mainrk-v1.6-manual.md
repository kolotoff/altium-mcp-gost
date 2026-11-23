# MainRK v1.6 manual wording

Use this reference for MainRK R1-100 v1.6 and MainRK R4-60 v1.6. It records
the accepted wording from their joint review. Treat the current approved board
JSON as the baseline for other details. Recheck affected facts against read-only
Altium and the named ArduPilot target if the hardware, assembly, or firmware
changes.

## Shared structure

Use this order for both boards.

1. Cover with «Описание платы и распиновка разъёмов».
2. «Общий вид платы», top then bottom. Introduction «На видах сверху и снизу показано расположение разъёмов и органов управления.»
3. «Карта интерфейсов платы», top then bottom at 1.2:1. Use a horizontal processor legend and a vertical power legend at the lower right for qualifying domains.
4. «Назначение», «Процессоры и полётный контроллер», «Память», «Бортовые датчики и контроль питания», «Кнопка, переключатель и перемычки».
5. «Выходы питания на разъёмах», followed by «Вход питания и исполнительные устройства», «Разъёмы полётного контроллера и расширения», «Системные и периферийные разъёмы», and «Органы управления и сервисные элементы».

In «Назначение», use the same row order for configuration, power, dimensions,
and Ethernet. Use the actual variant dimensions and Ethernet designator. The
shared power sentence is «Аккумулятор 3S–6S подключается к разъёму XT60 (X2).
Предельное входное напряжение — 30 В.» The configuration row names the board's
actual devices. Omit the generic «Основные функции» row and board-marking
provenance in the reader-facing text.

Use Arial and deliver ODT/PDF pairs with the established base names. Center the
whole-board artwork and keep each connector crop, pinout, and contact table on
one page when it fits. Preserve the native installed-side body or pads, original
pad endpoints, and the mirrored X16/X17 fan-out on R1-100. Use XP1's pattern of
even label spacing and symmetric leader offsets as the reference for that pair.

## Shared wording and controls

Use these sentences for both boards when the underlying facts match. Reuse the
same wording in the overview and connector section when both carry the same
operation.

| Field | Approved Russian wording |
| --- | --- |
| Полётный контроллер | STM32H743VIH6 с ядром Cortex-M7 до 480 МГц, 2 МБ флеш-памяти и 1 МБ оперативной памяти. |
| Связь процессоров | Вычислитель RK3588 и полётный контроллер связаны по UART. На RK3588 используется UART8 (M0), на STM32H743 — USART1 (SERIAL1 в ArduPilot). RK3588 также управляет сбросом STM32 и выбором режима его загрузки. |
| Загрузочная память | Микросхема SPI NOR ёмкостью 16 МБ входит в один из вариантов комплектации. В стандартной комплектации не устанавливается. |
| MMC5603NJ | В одном из вариантов комплектации магнитометр подключён к шине I²C3 по адресу 0x30. В стандартной комплектации не устанавливается. |
| Барометр | Барометр DPS310 подключён к I²C3 (BUS2 в ArduPilot) по адресу 0x77. Предусмотрен вариант комплектации с DPS368. |
| XP1 | Разъём для внешнего инерциального модуля, его нагревателя и датчиков температуры. |
| XP4 — Отладочный разъём | На XP4 выведены SWD и USART1/USART2 полётного контроллера, UART2 и UART0 вычислителя RK3588, USB, питание и служебные сигналы. |
| XS1 — Сервисный USB Type-C | Сервисный порт USB 2.0 Type-C. На дополнительные контакты выведены служебные линии USB, в том числе для моста USB–UART, линии SWD и сигнал режима обновления. |
| SB4 — Пользовательская кнопка | В отпущенном положении контакты разомкнуты. При нажатии SB4 соединяет вход BUTTON1 процессора RK3588 с землёй. |
| B2 — Резервный элемент RTC | Перезаряжаемый элемент ML414H поддерживает работу часов реального времени HYM8563S при отключённом основном питании. |
| Введение к таблице питания | Домен VCC_5V питается от общего преобразователя на 5 А. Для защищённых ветвей указан номинал предохранителя. |

- Keep the 24 MHz board clock out of the flight-controller overview. Describe
  the configured shunt value with «В штатном профиле используется сопротивление
  шунта …» where the target supplies a verified value.
- XP4 taps the inter-processor UART and also exposes other service interfaces.
  Describe the processor link under «Связь процессоров». Use «Отладочный
  разъём» consistently wherever XP4's role is named. The USB–UART bridge takes
  USB D± from XS1. Omit the power-off signal from the XS1 summary and retain
  its verified contact and net in the pin table and exports.
- Use the same SA1 text in the controls overview and the selector section.
  Name the connector, the two processors, and all three supported operations.

  > SA1 выбирает, к чему подключён USB разъёма XS1. При SA1-1 OFF и SA1-2 ON USB подключён к вычислителю RK3588 в обычном режиме. Если обе секции в положении OFF, USB по умолчанию подключён к полётному контроллеру. Для входа RK3588 в режим обновления (Maskrom) установите обе секции в положение ON до запуска вычислителя.

- Preserve the approved DPS310/DPS368 wording. Both firmware targets configure
  DPS310, and the compiled Altium part record lists DPS368. Verify the assembly
  bill of materials before making any claim about the fitted-by-default part.
- X2 uses «К разъёму XT60 подключается аккумуляторная батарея.» X10 uses
  «Двухконтактный разъём вентилятора на 5 В. Полётный контроллер включает
  вентилятор через [вывод] ([GPIO] в ArduPilot).» Substitute the values below.
- For each motor output, use «На разъём выведены три фазы встроенного
  ESC-регулятора двигателя [номер]. Регулятор управляется сигналом [канал]
  ([SERVO] в ArduPilot).» Use the motor number where present. Use
  «ESC-регулятор» in the overview as well.

## Variant data and names

| Field | R1-100 v1.6 | R4-60 v1.6 |
| --- | --- | --- |
| ArduPilot target | `BERSW-743-v1-6` | `BER-743-v1-6` |
| Размеры | 146,00 × 62,00 мм | 172,50 × 51,60 мм |
| Встроенный Ethernet | X6 | XP5 |
| X10 fan control | PE1 / GPIO80 | PB12 / GPIO81 |
| Motor connectors | XP2 uses TIM2_CH1 / SERVO9 | X5_1 uses TIM3_CH3 / SERVO1, X5_2 uses TIM2_CH1 / SERVO2, X5_3 uses TIM5_CH3 / SERVO3, X5_4 uses TIM4_CH1 / SERVO4 |

- **R1-100**. X3 and X4 are the first and second camera heater connectors.
  Use «Нагреватель камеры 1» and «Нагреватель камеры 2» across the summary,
  connector text, and map. X7 and X9 are grounded Keystone 5016 test contacts.
  State «В стандартной комплектации не устанавливается» and let the crop
  show the side. X8, X11, and X12 use RK3588 UART3 (M2), UART7 (M1), and
  UART9 (M1). Name the silicon peripheral in the connector title, text, map,
  and function labels. Keep the exact routing aliases in pin records. X13
  exposes PWM10 and PWM11. Use «Трёхконтактный разъём JST GH для управления
  сервоприводом.» for X23, X21, X25, X19, X26, X24, X22, and X20.
- **R4-60**. XP9 exposes USB 2.0, RK3588 UART9 (M1), STM32 UART4 (SERIAL4 in
  ArduPilot), RK3588 PWM10/PWM11, GPIO, and three supply lines. Keep the
  numbered peripheral and its logical firmware port distinct.
- **Both**. XP8 exposes RK3588 UART0 (M2), the gimbal debug UART through
  channel 3 of the USB–UART bridge, two GPIO lines, input voltage, and 5 V.

Use the approved JSON's individual contacts and branch ratings for the power
table. The shared VCC_5V rating belongs to the common converter. Label branch
ratings with their actual basis and use «—» when an individual current has no
verified value.
