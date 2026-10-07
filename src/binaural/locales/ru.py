"""Russian catalogue: English source string -> Russian text.

Keys are the English source strings exactly as they are passed to
:func:`binaural.i18n.tr`, which keeps the source language readable in the code
and lets a missing key fall back to English instead of to an empty label.

Style: calm and factual, no marketing and no medical promises (SPEC §6.13 —
the app is not a medical device). Terminology follows ``README.ru.md``:
binaural beats -> бинауральные биения, beat -> биение, carrier -> несущая,
headphones -> наушники, evidence -> обоснованность.

Placeholders (``%1``, ``{label}``) are kept verbatim: only the surrounding
wording is translated.
"""

from __future__ import annotations

MESSAGES: dict[str, str] = {
    # --- main window ------------------------------------------------------
    "Binaural": "Binaural",
    "LEFT EAR": "ЛЕВОЕ УХО",
    "RIGHT EAR": "ПРАВОЕ УХО",
    "Play": "Воспроизвести",
    "Stop": "Остановить",
    "Play or stop the binaural tone": "Запустить или остановить бинауральный тон",
    "Play the binaural tone": "Запустить бинауральный тон",
    "Stop the binaural tone": "Остановить бинауральный тон",
    "Starts or stops playback. The keyboard shortcut is Space.": (
        "Запускает или останавливает воспроизведение. Горячая клавиша — пробел."
    ),
    "Volume": "Громкость",
    "Output level from 0 to 100 percent. Not medical advice: keep it low.": (
        "Уровень вывода от 0 до 100 процентов. Это не медицинская рекомендация: "
        "держите громкость низкой."
    ),
    "Presets": "Пресеты",
    "Save preset": "Сохранить пресет",
    "Saves the current pair of frequencies for the next run.": (
        "Сохраняет текущую пару частот до следующего запуска."
    ),
    "Sets both channels around a %1 Hz carrier so the difference is %2 Hz.": (
        "Задаёт оба канала вокруг несущей %1 Гц так, что разность равна %2 Гц."
    ),
    # --- preset registry (SPEC §5 F3) --------------------------------------
    # English source strings of `ui/presets.py`; the Russian text of the registry lives
    # here so that one catalogue holds every Russian caption (SPEC §7.4).
    "Shows the %1 presets: %2.": "Показывает пресеты «%1»: %2.",
    "Delta": "Дельта",
    "Theta": "Тета",
    "Alpha": "Альфа",
    "Beta": "Бета",
    "Gamma": "Гамма",
    "Sleep": "Сон",
    "Meditation": "Медитация",
    "Relaxation": "Расслабление",
    "Awareness": "Ясность",
    "Concentration": "Сосредоточенность",
    "Work": "Работа",
    "Sport": "Спорт",
    "Current frequencies: left %1, right %2.": "Текущие частоты: слева %1, справа %2.",
    "Preset name": "Название пресета",
    "This preset is remembered for the next start.": (
        "Этот пресет сохраняется до следующего запуска."
    ),
    "Name:": "Название:",
    "Preset applied: difference %1 Hz": "Пресет применён: разность %1 Гц",
    # --- playback timer (SPEC §5 F5) --------------------------------------
    "Timer": "Таймер",
    "Off": "Выкл.",
    "%1 min": "%1 мин",
    "How long a session plays before it stops by itself.": (
        "Сколько длится сессия до автоматической остановки."
    ),
    "How long a new session plays before it stops by itself.": (
        "Сколько будет длиться новая сессия до автоматической остановки."
    ),
    "Time left": "Осталось времени",
    "Time left: %1": "Осталось времени: %1",
    "The timer is off.": "Таймер выключен.",
    # --- settings dialog (SPEC §7) ----------------------------------------
    "Settings": "Настройки",
    "Settings are not available in this build.": "Настройки недоступны в этой сборке.",
    "Switch the interface language straight away.": (
        "Переключает язык интерфейса сразу же."
    ),
    "Run the headphone check again": "Повторить проверку наушников",
    "Re-reads the default audio output device and offers the L/R test.": (
        "Перечитывает устройство аудиовыхода по умолчанию и предлагает тест L/R."
    ),
    "Close the settings": "Закрыть настройки",
    "Active channel: %1": "Активный канал: %1",
    "Error": "Ошибка",
    "Could not start audio output.": "Не удалось запустить аудиовыход.",
    "Frequency reference": "Справочник частот",
    "The frequency reference is not available in this build.": (
        "Справочник частот недоступен в этой сборке."
    ),
    "About Binaural": "О программе Binaural",
    "<b>Binaural %1</b><br><br>"
    "Two independent frequencies, one perceived difference.<br><br>"
    "These frequencies and effect descriptions come from research as well "
    "as esoteric, energy and alternative practices. This app is not a medical "
    "device and is not intended for diagnosis, treatment or prevention of any "
    "disease. Do not use it with epilepsy, a pacemaker, during pregnancy, or "
    "with photosensitivity without consulting a doctor. Do not raise the volume.": (
        "<b>Binaural %1</b><br><br>"
        "Две независимые частоты и одна воспринимаемая разность.<br><br>"
        "Эти частоты и описания эффектов происходят из исследовательской литературы "
        "и из эзотерических, энергетических и альтернативных практик. Приложение "
        "не является медицинским изделием и не предназначено для диагностики, лечения "
        "или профилактики заболеваний. Не используйте его при эпилепсии, "
        "кардиостимуляторе, во время беременности и при повышенной светочувствительности "
        "без консультации врача. Не превышайте разумную громкость."
    ),
    # --- menus (incl. the language switch) ---------------------------------
    "&View": "&Вид",
    "Language": "Язык",
    "&Settings…": "&Настройки…",
    "&Help": "&Справка",
    "Frequency &reference…": "Справочник &частот…",
    "&Check headphones…": "Проверить &наушники…",
    "&About": "&О программе",
    # --- beat card ---------------------------------------------------------
    "BEAT": "БИЕНИЕ",
    "CARRIER": "НЕСУЩАЯ",
    "Hz": "Гц",
    "1 – 20000 Hz": "1 – 20000 Гц",
    "Beat and carrier frequencies": "Частота биения и несущая",
    "Difference between the channels: %1 hertz": "Разность между каналами: %1 Гц",
    "Mean of the two channels: %1 hertz": "Среднее двух каналов: %1 Гц",
    "Beat %1 hertz, carrier %2 hertz": "Биение %1 Гц, несущая %2 Гц",
    "Difference is %1 Hz — outside the %2–%3 Hz range the ear usually "
    "perceives as a beat.": (
        "Разность %1 Гц — вне диапазона %2–%3 Гц, который ухо обычно "
        "воспринимает как биение."
    ),
    "Pulsing beat indicator": "Пульсирующий индикатор биения",
    "Static beat indicator": "Статический индикатор биения",
    "Reduced motion is on — the beat indicator stays still.": (
        "Уменьшенная анимация включена — индикатор биения остаётся неподвижным."
    ),
    "Note": "Примечание",
    "Warning": "Предупреждение",
    # --- lock difference (SPEC §7) -----------------------------------------
    "Lock difference": "Зафиксировать",
    "Keeps the difference between the two frequencies. Changing one channel moves the "
    "other by the same amount, so the beat stays the same.": (
        "Держит разность между частотами. Изменение одного канала сдвигает другой на "
        "столько же, поэтому биение остаётся прежним."
    ),
    "Difference lock turned off — a preset set its own difference.": (
        "Фиксация разности выключена — пресет задал свою разность."
    ),
    "Stopped at the range limit: the difference is locked, so the other channel cannot "
    "follow any further.": (
        "Остановлено на границе диапазона: разность зафиксирована, поэтому второй канал "
        "не может следовать дальше."
    ),
    # --- per-ear frequency control ----------------------------------------
    "Frequency for %1, from 1 to 20000 hertz. Use the arrow keys for 0.1 hertz steps.": (
        "Частота для %1, от 1 до 20000 Гц. Шаг стрелками — 0,1 Гц."
    ),
    "%1 frequency in hertz": "Частота %1 в герцах",
    "%1 frequency slider": "Ползунок частоты %1",
    "Type an exact value between 1 and 20000, in steps of 0.1 hertz.": (
        "Введите точное значение от 1 до 20000 с шагом 0,1 Гц."
    ),
    "Sweeps the frequency from 1 to 20000 hertz.": (
        "Плавно меняет частоту от 1 до 20000 Гц."
    ),
    # --- status indicator --------------------------------------------------
    "Audio output status": "Состояние аудиовыхода",
    "Headphones detected": "Наушники обнаружены",
    "Binaural beats are rendered correctly.": "Бинауральные биения формируются верно.",
    "Speakers detected — binaural beats need headphones": (
        "Обнаружены динамики — для бинауральных биений нужны наушники"
    ),
    "On speakers the two tones mix in the air, so the beat disappears. "
    "Use headphones for the effect.": (
        "На динамиках два тона смешиваются в воздухе, поэтому биение исчезает. "
        "Для эффекта нужны наушники."
    ),
    "Unknown device": "Устройство не определено",
    "Could not identify the audio output device.": (
        "Не удалось определить устройство аудиовыхода."
    ),
    # --- audio engine errors -----------------------------------------------
    "Audio is working.": "Аудио работает.",
    "Could not open the audio output device.": "Не удалось открыть устройство аудиовыхода.",
    "Audio device I/O error while writing samples.": (
        "Ошибка ввода-вывода аудиоустройства при записи выборок."
    ),
    "Audio device underrun: the buffer ran dry.": "Буфер аудиоустройства опустел.",
    "Fatal audio error. Please restart the application.": (
        "Критическая ошибка аудио. Перезапустите приложение."
    ),
    "Unknown audio error.": "Неизвестная ошибка аудио.",
    "Audio output is not available in this build.": "Аудиовыход недоступен в этой сборке.",
    "No audio output device found.": "Устройство аудиовыхода не найдено.",
    "Could not create the audio sink: {}": "Не удалось создать приёмник аудио: {}",
    # --- shared dialog helpers --------------------------------------------
    "Open project page": "Открыть страницу проекта",
    "Open {url} in the browser": "Открыть {url} в браузере",
    "Close": "Закрыть",
    "Disclaimer": "Дисклеймер",
    "Medical disclaimer — read it before using the application.": (
        "Медицинский дисклеймер — прочитайте перед использованием приложения."
    ),
    "These frequencies and the descriptions of their effects come from research, "
    "and also from esoteric, energy and alternative practices. This application is "
    "not a medical device and is not intended for the diagnosis, treatment or "
    "prevention of any disease. Do not use it if you have epilepsy or a pacemaker, "
    "during pregnancy, or if you are photosensitive, without consulting a doctor. "
    "Do not turn the volume above a comfortable level. "
    "Binaural beats are sound, not a substance, and they do not replace one. "
    "Nothing here helps with withdrawal, craving, tolerance or relapse, and this "
    "app does not treat dependence of any kind. Dependence is a medical condition "
    "with risks of its own: withdrawal from alcohol and from sedatives can be "
    "dangerous. If you are dependent on something, or want to use less of it, that "
    "is a question for a doctor or a specialist service, not for a tone generator.": (
        "Эти частоты и описания их эффектов происходят из исследовательской "
        "литературы, а также из эзотерических, энергетических и альтернативных "
        "практик. Это приложение не является медицинским изделием и не "
        "предназначено для диагностики, лечения или профилактики заболеваний. "
        "Не используйте его при эпилепсии или кардиостимуляторе, во время "
        "беременности, а также при повышенной светочувствительности без "
        "консультации врача. Не превышайте разумную громкость. "
        "Бинауральные биения — это звук, а не вещество, и они его не заменяют. "
        "Ничто здесь не помогает при абстиненции, тяге, толерантности или "
        "рецидиве, и приложение не лечит никакую зависимость. Зависимость — это "
        "медицинское состояние со своими рисками: абстиненция от алкоголя и "
        "седативных препаратов может быть опасна. Если вы зависимы от чего-либо "
        "или хотите употреблять меньше, это вопрос к врачу или специализированной "
        "службе, а не к генератору тонов."
    ),
    # --- system tray (src/binaural/ui/tray.py) -----------------------------
    "⏹ %1 / %2 Hz": "⏹ %1 / %2 Гц",
    "▶ %1 / %2 Hz — beat %3 Hz": "▶ %1 / %2 Гц — биение %3 Гц",
    # "Play" and "Stop" are already listed under the main window above.
    "Show Binaural": "Показать Binaural",
    "Hide Binaural": "Скрыть Binaural",
    "Frequency reference…": "Справочник частот…",
    "Check headphones…": "Проверить наушники…",
    "Quit": "Выход",
    "Medical and safety disclaimer.": "Медицинский дисклеймер и техника безопасности.",
    "Show or hide the medical disclaimer": "Показать или скрыть медицинский дисклеймер",
    # --- About dialog ------------------------------------------------------
    "Binaural beats for macOS and Linux": "Бинауральные биения для macOS и Linux",
    "Two sine tones of different frequency are sent to the left and the right ear. "
    "Your brain fuses them into a third tone that has no sound source: the difference "
    "between the two frequencies. That phantom tone is the binaural beat.": (
        "В левое и правое ухо отправляются два синусоидальных тона разной частоты. "
        "Мозг сливает их в третий тон, у которого нет источника звука: это разность "
        "двух частот. Именно этот фантомный тон и называется бинауральным биением."
    ),
    "Headphones are a physical requirement, not a recommendation: on speakers both "
    "frequencies mix in the air before they reach your ears, and the effect is gone. "
    "The application checks the audio output on every start and reports what it found.": (
        "Наушники здесь не рекомендация, а физическое требование: на динамиках обе "
        "частоты смешиваются в воздухе раньше, чем достигают ушей, и эффект "
        "пропадает. Приложение проверяет аудиовыход при каждом запуске и сообщает, "
        "что оно нашло."
    ),
    "The frequency reference keeps every record it has — from peer-reviewed EEG "
    "literature to esoteric traditions — each marked with how well it is studied.": (
        "Справочник частот хранит все записи, которые у него есть, — от "
        "рецензируемой литературы по ЭЭГ до эзотерических традиций — и у каждой "
        "отмечено, насколько она изучена."
    ),
    "Version {version} · Python {python} · PySide6 {qt}": (
        "Версия {version} · Python {python} · PySide6 {qt}"
    ),
    "Close the About dialog": "Закрыть окно «О программе»",
    "MIT License": "Лицензия MIT",
    "Copyright (c) {year} {holder}": "© {year} {holder}",
    "Permission is hereby granted, free of charge, to any person obtaining a copy of "
    'this software and associated documentation files (the "Software"), to deal in '
    "the Software without restriction, including without limitation the rights to use, "
    "copy, modify, merge, publish, distribute, sublicense and/or sell copies of the "
    "Software, and to permit persons to whom the Software is furnished to do so, "
    "subject to the conditions of the MIT licence. The software is provided \"as is\", "
    "without warranty of any kind, express or implied.": (
        "Предоставляется бесплатно любому лицу, получившему копию данного "
        "программного обеспечения и сопутствующей документации (далее — "
        "«Программное обеспечение»), на использование без ограничений, включая "
        "право использования, копирования, изменения, слияния, публикации, "
        "распространения, сублицензирования и продажи копий Программного "
        "обеспечения, при условии, что в уведомлениях об использовании "
        "Программного обеспечения сохраняется указанное выше уведомление об "
        "авторском праве и настоящее условие. Программное обеспечение "
        "предоставляется «как есть», без каких-либо гарантий, явных или подразумеваемых."
    ),
    # --- headphone check dialog --------------------------------------------
    "Headphones recommended": "Рекомендуются наушники",
    "Binaural beats only work when each ear receives its own tone. On speakers the "
    "two frequencies mix in the air before reaching your ears, and the effect "
    "disappears. You can continue anyway — the app will keep showing a "
    "“Speakers detected” indicator in the status bar.": (
        "Бинауральные биения работают, только когда каждое ухо получает свой тон. "
        "На динамиках две частоты смешиваются в воздухе раньше, чем достигают ушей, "
        "и эффект исчезает. Можно продолжить всё равно — приложение будет "
        "показывать в строке состояния индикатор «Обнаружены динамики»."
    ),
    "This check can be repeated at any time from the Help menu.": (
        "Эту проверку можно повторить в любой момент из меню «Справка»."
    ),
    "Speakers detected": "Обнаружены динамики",
    "Virtual audio device — cannot tell what is playing": (
        "Виртуальное аудиоустройство — нельзя определить, что играет"
    ),
    "Output device not recognised — run the L/R test": (
        "Выходное устройство не распознано — выполните тест L/R"
    ),
    "Headphones": "Наушники",
    "Speakers": "Динамики",
    "Virtual device": "Виртуальное устройство",
    "Unknown": "Неизвестно",
    "Unknown output device": "Неизвестное устройство вывода",
    "Device": "Устройство",
    "Verdict": "Вердикт",
    "Confidence": "Уверенность",
    "High": "Высокая",
    "Medium": "Средняя",
    "Low": "Низкая",
    "L/R test: Left → Right — headphones confirmed, channels correct.": (
        "Тест L/R: слева → справа — наушники подтверждены, каналы верны."
    ),
    "L/R test: Right → Left — headphones confirmed, channels are swapped. "
    "Binaural will swap them when generating.": (
        "Тест L/R: справа → слева — наушники подтверждены, каналы перепутаны. "
        "Binaural поменяет их местами при генерации."
    ),
    "L/R test: both at once or unclear — this sounds like speakers or a mono mixer.": (
        "Тест L/R: оба тона сразу или непонятно — похоже на динамики или моно-микшер."
    ),
    "Run L/R test": "Запустить тест L/R",
    "Run the perceptual left/right channel test": (
        "Запустить перцептивный тест левого/правого канала"
    ),
    "Plays a tone in the left ear, then the right ear, and asks what you heard.": (
        "Проигрывает тон в левом ухе, затем в правом, и спрашивает, что вы услышали."
    ),
    "Retry check": "Проверить снова",
    "Run the device check again": "Повторить проверку устройства",
    "Re-reads the default audio output device.": (
        "Перечитывает устройство аудиовыхода по умолчанию."
    ),
    "Continue anyway": "Продолжить всё равно",
    "Continue anyway, even without confirmed headphones": (
        "Продолжить всё равно, даже если наушники не подтверждены"
    ),
    "Nothing is blocked; the app will keep the speakers warning in the status bar.": (
        "Ничего не блокируется: приложение продолжит показывать предупреждение о "
        "динамиках в строке состояния."
    ),
    # --- L/R test dialog ----------------------------------------------------
    "Left / right channel test": "Тест левого/правого канала",
    "You will hear a tone in one ear, then a pause, then a tone in the other ear. "
    "Tell us what you heard.": (
        "В одном ухе прозвучит тон, затем будет пауза, затем тон в другом ухе. "
        "Расскажите, что вы услышали."
    ),
    "What did you hear?": "Что вы услышали?",
    'Ready. Press "Play test" and listen.': "Готово. Нажмите «Запустить тест» и слушайте.",
    "Answer recorded.": "Ответ записан.",
    "Playing in LEFT ear…": "Воспроизведение в ЛЕВОМ ухе…",
    "Pause…": "Пауза…",
    "Playing in RIGHT ear…": "Воспроизведение в ПРАВОМ ухе…",
    "Left → Right": "Слева → справа",
    "The first tone came from the left ear: the channels are correct.": (
        "Первый тон прозвучал слева: каналы верны."
    ),
    "Right → Left": "Справа → слева",
    "The channels are swapped. The application will swap them for you.": (
        "Каналы перепутаны. Приложение поменяет их местами."
    ),
    "Both at once / Can't tell": "Оба сразу / Не разобрать",
    "Sounds like speakers or a mono mixer, where no beat can be perceived.": (
        "Похоже на динамики или моно-микшер, где биение не воспринимается."
    ),
    "{answer}. {hint}": "{answer}. {hint}",
    "Headphones confirmed, the channels are correct.": (
        "Наушники подтверждены, каналы верны."
    ),
    "Headphones confirmed, but the channels are swapped. Binaural will swap them "
    "so the beat stays on the side you expect.": (
        "Наушники подтверждены, но каналы перепутаны. Binaural поменяет их местами, "
        "чтобы биение осталось с той стороны, с которой вы его ожидаете."
    ),
    "No clear answer. This usually means speakers or a mono mixer.": (
        "Ясного ответа нет. Скорее всего, это динамики или моно-микшер."
    ),
    "No audio output is available, so the test cannot be played. Check your sound "
    "settings and try again.": (
        "Аудиовыход недоступен, поэтому тест нельзя воспроизвести. Проверьте настройки "
        "звука и попробуйте снова."
    ),
    "The audio output did not start. Check the volume and the selected output device.": (
        "Аудиовыход не запустился. Проверьте громкость и выбранное устройство вывода."
    ),
    "Play test": "Запустить тест",
    "Play test again": "Запустить тест снова",
    "Play the left/right test sequence": (
        "Запустить последовательность теста левого и правого уха"
    ),
    "A short tone in the left ear, a pause, then the right ear.": (
        "Короткий тон в левом ухе, пауза, затем в правом."
    ),
    "Close the test without answering": "Закрыть тест без ответа",
    "Could not start the test: {error}": "Не удалось запустить тест: {error}",
    "Tone: {freq} Hz — one channel at a time, no beat": (
        "Тон: {freq} Гц — по одному каналу за раз, без биения"
    ),
    # --- frequency reference dialog ----------------------------------------
    "Every record from the built-in reference, from EEG literature to esoteric "
    "traditions. Nothing is ranked and nothing is hidden.": (
        "Все записи встроенного справочника — от литературы по ЭЭГ до эзотерических "
        "традиций. Ничего не ранжировано и ничего не скрыто."
    ),
    "Search the frequency reference": "Поиск по справочнику частот",
    "Search name, frequency or effect…": "Поиск по названию, частоте или эффекту…",
    "Filter by evidence level": "Фильтр по уровню обоснованности",
    "All evidence": "Все уровни",
    "Well-studied": "Хорошо изучено",
    "Studied": "Изучено",
    "Reported": "Сообщается",
    "Traditional": "Традиционное",
    "Badges show how well a record is studied. Nothing is hidden by default.": (
        "Значки показывают, насколько хорошо изучена запись. По умолчанию ничего "
        "не скрыто."
    ),
    "Reference categories": "Категории справочника",
    "Categories": "Категории",
    "Reference records": "Записи справочника",
    "All categories": "Все категории",
    "Show every record of the reference": "Показать все записи справочника",
    "Nothing matches this filter.": "По этому фильтру ничего не найдено.",
    "Showing {shown} of {total} records": "Показано {shown} из {total} записей",
    "Apply": "Применить",
    "Apply {label}": "Применить «{label}»",
    "Carries {carrier} Hz": "Несущая {carrier} Гц",
    "Tone — applied as the carrier with a {beat} Hz beat": (
        "Тон — применяется как несущая с биением {beat} Гц"
    ),
    "Set left = {left} Hz and right = {right} Hz (difference {beat})": (
        "Слева = {left} Гц, справа = {right} Гц (разность {beat})"
    ),
    "Close the frequency reference": "Закрыть справочник частот",
}