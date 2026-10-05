# Контракт API

Единый источник сигнатур для всех исполнителей. **Менять контракт может только
координатор** — если контракт мешает, напиши почему, но не переопределяй молча.

Спецификация: [`docs/SPEC.md`](SPEC.md).

---

## 1. `binaural.core.oscillator`

```python
DEFAULT_CARRIER_HZ: float = 200.0
MIN_FREQ_HZ: float = 1.0
MAX_FREQ_HZ: float = 20000.0
MAX_BEAT_HZ: float = 100.0          # вне — подсказка, не ошибка
RECOMMENDED_BEAT_HZ: tuple[float, float] = (0.5, 100.0)


def beat_frequency(left_hz: float, right_hz: float) -> float:
    """|fL - fR|."""

def carrier_frequency(left_hz: float, right_hz: float) -> float:
    """(fL + fR) / 2."""

def pair_from_beat(beat_hz: float, carrier_hz: float = DEFAULT_CARRIER_HZ) -> tuple[float, float]:
    """(fL, fR) дающие заданную разность вокруг несущей. fL = c - b/2, fR = c + b/2."""


class StereoOscillator:
    """Два синусоидальных осциллятора с независимыми частотами и непрерывной фазой."""

    def __init__(self, sample_rate: int = 48000) -> None: ...

    @property
    def sample_rate(self) -> int: ...
    @property
    def left_hz(self) -> float: ...
    @property
    def right_hz(self) -> float: ...

    def set_frequencies(self, left_hz: float, right_hz: float) -> None:
        """Новая частота применяется без разрыва фазы; текущая фаза сохраняется."""

    def set_fade(self, gain: float, ramp_seconds: float = 0.03) -> None:
        """Целевая амплитуда 0..1, достижение плавное за ramp_seconds."""

    def render(self, frames: int) -> tuple[list[float], list[float]]:
        """Генерирует block float32-подобных выборок: (left, right).
        Применяет fade-состояние. Длина каждого списка == frames.
        Вызывается только из аудио-потока, без аллокаций в горячем цикле."""
```

**Свойства, обязательные к соблюдению:**
- фаза **не сбрасывается** при смене частоты → нет щелчков
- fade реализуется **накоплением** к целевой амплитуде, не линейной интерполяцией по блоку
- `render` не бросает исключений и не пишет в лог

---

## 2. `binaural.core.engine`

```python
class AudioEngine(QObject):
    """Вывод стереосигнала. Реализация на QtMultimedia (QAudioSink)."""

    started = Signal()
    stopped = Signal()
    error = Signal(str)                       # текст для пользователя

    def __init__(self, oscillator: StereoOscillator, parent: QObject | None = None): ...

    @property
    def is_running(self) -> bool: ...
    @property
    def volume(self) -> float: ...            # 0..1
    @volume.setter
    def volume(self, value: float) -> None: ...

    def start(self) -> bool:
        """False + сигнал error, если устройство недоступно."""
    def stop(self) -> None: ...
    def shutdown(self) -> None:
        """Гарантированно останавливает и освобождает устройство."""
```

Если `QAudioSink` недоступен — движок поднимает `error`, UI показывает текст.
Резервная реализация на `miniaudio` опциональна (P2), интерфейс тот же.

---

## 3. `binaural.audio.platform`

```python
class DeviceClass(Enum):
    HEADPHONES = "headphones"     # наверняка
    SPEAKERS = "speakers"
    VIRTUAL = "virtual"           # BlackHole, Loopback, монитор
    UNKNOWN = "unknown"

@dataclass(frozen=True)
class AudioDevice:
    name: str
    transport: str                # "bluetooth" | "usb" | "builtin" | "hdmi" | "displayport"
                                  # | "airplay" | "pci" | "virtual" | "unknown"
    is_default: bool = False
    identifier: str = ""


class AudioBackend(Protocol):
    def list_outputs(self) -> list[AudioDevice]: ...
    def default_output(self) -> AudioDevice | None: ...
    def classify(self, device: AudioDevice) -> DeviceClass: ...
    def heuristic_verdict(self) -> tuple[DeviceClass, AudioDevice | None]:
        """Вердикт по дефолтному устройству: (класс, устройство)."""


def get_backend() -> AudioBackend:
    """Фабрика: sys.platform == 'darwin' -> macos, 'linux' -> linux.
    Иначе -> NullBackend (list_outputs пуст, classify UNKNOWN)."""
```

**`macos.py`** — CoreAudio через `ctypes`:
`kAudioHardwarePropertyDevices`, `kAudioDevicePropertyTransportType`,
`kAudioDevicePropertyDeviceNameCFString`, `kAudioHardwarePropertyDefaultOutputDevice`.
Транспорт FourCC → строка (значения: `'blth'`, `'blet'`, `'usb '`, `'buit'`, `'hdmi'`,
`'dp  '`, `'airp'`, `'pci '`, `'virt'`).

**`linux.py`** — `pactl list sinks` → `pw-cli` → `amixer`, первый доступный.
Порт вида `[Out] Headphone` → `HEADPHONES`, `[Out] Speaker` → `SPEAKERS`.
Все вызовы — с таймаутом ≤ 2 с и `try/except`; падение = `UNKNOWN`, не краш.

**Ключевое свойство:** любое падение детекта сводится к `UNKNOWN`.
Дальше всё решает перцептивный тест (§4.2 SPEC) — он **общий код** и не зависит от ОС.

---

## 4. `binaural.audio.headphones`

```python
class LrTestResult(Enum):
    LEFT_THEN_RIGHT = "left_then_right"      # каналы верны
    RIGHT_THEN_LEFT = "right_then_left"      # каналы перепутаны
    INDETERMINATE = "indeterminate"          # колонки / моно

@dataclass(frozen=True)
class HeadphoneReport:
    verdict: DeviceClass
    device: AudioDevice | None
    confidence: str                          # "high" | "medium" | "low"
    lr_test: LrTestResult | None = None

    @property
    def is_headphones(self) -> bool: ...
    @property
    def channels_swapped(self) -> bool: ...


def detect(report: HeadphoneReport | None = None) -> HeadphoneReport:
    """Эвристика. Без звука, без вопросов."""

def run_lr_test(engine: AudioEngine) -> LrTestResult:
    """Играет тон влево, пауза, вправо. Возвращает результат ответа пользователя.
    Реальный ответ собирает UI — функция только воспроизводит и отдаёт состояния."""
```

`channels_swapped == True` → приложение **меняет каналы местами** при генерации.

---

## 5. `binaural.data.frequencies`

Файл: `src/binaural/data/frequencies.json`, схема — §6.2 SPEC.

```python
@dataclass(frozen=True)
class Category:
    id: str; order: int; icon: str; color: str
    label_en: str; label_ru: str
    description_en: str; description_ru: str

@dataclass(frozen=True)
class FrequencyEntry:
    id: str; category: str; label: str
    beat_hz: float | None                   # либо beat_hz, либо beat_min/beat_max
    beat_min: float | None; beat_max: float | None
    carrier_hz: float
    effect_en: str; effect_ru: str
    evidence: str                           # well-studied|studied|reported|traditional
    source: str; tags: list[str]


def load() -> tuple[list[Category], list[FrequencyEntry]]:
    """Кэшируется. Категории отсортированы по order."""

def categories_with_counts() -> list[tuple[Category, int]]: ...
def search(query: str, category: str | None = None) -> list[FrequencyEntry]: ...
def evidence_badge(evidence: str) -> str:
    """'🟢' | '🔵' | '🟡' | '🟣'"""
```

Валидируется в тестах: уникальность `id`, существование `category`,
`evidence` из допустимого набора, `beat_hz > 0`.

---

## 6. `binaural.ui`

Классы: `MainWindow`, `FreqControl` (левый/правый), `BeatDisplay`,
`HeadphoneCheckDialog`, `LrTestDialog`, `ReferenceDialog`, `AboutDialog`.

**Сигналы `MainWindow`:**
```python
frequencies_changed = Signal(float, float)   # left, right
playback_toggled = Signal(bool)
```

**Хоткеи:** Space — play/stops, `↑/↓` — ±0.1 Гц активного канала,
`←/→` — переключение канала, `Cmd/Ctrl+O` — справочник, `Esc` — закрыть модалку.

**Диалог проверки при запуске** — модальный, но с `Continue anyway`.
Кнопка **не должна** быть заблокирована. Состояние запоминается в сессии (§ `session.py`).

**Язык UI — English + Русский**, переключается в меню `View → Language`.
Автопределение по системной локали, выбор хранится в QSettings `ui/language`.
Все строки через `tr()` → `binaural.i18n.tr()` (см. §6.1), каталог `binaural/locales/ru.py`.

---

## 7. `binaural.core.session`

```python
@dataclass
class Session:
    left_hz: float = 205.0
    right_hz: float = 215.0
    volume: float = 0.7
    channels_swapped: bool = False
    headphone_check_acknowledged: bool = False
    last_preset: str | None = None

def save(session: Session) -> None: ...      # QSettings, org "binaural", app "binaural"
def load() -> Session: ...
```

---

## Правила для исполнителей

1. **Не трогай файлы вне своего блока** — конфликты при параллельной работе.
2. Контракт менять нельзя без согласования; если нужно — остановись и объясни.
3. Весь пользовательский текст — через `tr()`; язык UI — **English + Русский**
   (исходник — английский, перевод — `binaural/locales/ru.py`, см. §6.1).
4. Комментарии в коде — **English**, короткие, только где «почему».
5. `core/` — **без импорта Qt** (кроме `engine.py`): чистая математика, тестируется.
6. Тесты обязательны для `core/`, `audio/platform`, `data`.
7. Прогон: `.venv/bin/python -m pytest` — должен быть зелёным.
8. Никаких новых зависимостей без согласования.
