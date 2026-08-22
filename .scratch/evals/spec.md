# План: минимальный eval для two-pane workflow

## Цель

Eval решает две задачи.

1. Проверяет, что выбранная дешёвая Main-модель соблюдает протокол из
   сгенерированного `SKILL.md`: использует только `./2pane send` и
   `./2pane take`, не обходит helper прямым доступом к runtime-файлам,
   сохраняет занятый слот и правильно трактует сообщение от своей роли.
2. Проверяет, что workflow сокращает расход токенов дорогой Expert-модели по
   сравнению с запуском той же Expert-модели на исходной задаче целиком.

Раннер — pi в print mode (`pi -p`). Грейдинг детерминированный: raw-сессия
(JSONL), результаты tool calls и состояние файлов. LLM-судья не используется.
Ответ модели остаётся стохастическим; для сравнимости раннер фиксирует
запрошенную и фактически использованную модель, thinking level, usage и все
параметры прогона.

## Изоляция и воспроизводимость

- Каждый прогон использует один фиксированный cwd:
  `/tmp/2pane-workflow-eval-workdir`. Стабильный путь позволяет один раз выдать
  pi per-project trust для `.agents/skills`.
- Раннер не запускает модель в исходном checkout. Перед каждым прогоном он
  безопасно пересоздаёт только этот заранее проверенный eval-workdir, копирует
  туда текущий `2pane`, делает его executable и выполняет `./2pane init`.
  Для economy fixture дополнительно копируются точно
  `docs/spec.md` и `docs/adr/0001-single-slot-inbox.md`. Другие файлы
  checkout в fixture не попадают.
- Одновременные запуски запрещены lock-каталогом, чтобы два раннера не делили
  cwd и inbox.
- После `init` раннер создаёт точный seed сценария и manifest всех файлов вне
  `.2pane`. После модели manifest должен остаться неизменным: модель не должна
  менять helper, skill или другие fixture-файлы.
- Каждый `scenario-rN` начинается с новой fixture. Поэтому S1 не влияет на
  следующий повтор или сценарий, а аварийное завершение не затрагивает
  пользовательский `.2pane`.
- `AGENT_ROLE`, `PI_CODING_AGENT_SESSION_DIR` и другие влияющие переменные
  сбрасываются явно перед каждым процессом. S1–S4 запускаются как Main.
  Economy suite явно запускает отдельные процессы Main и Expert с разными
  моделями.
- На каждый вызов pi действует timeout (по умолчанию 180 секунд). Timeout,
  отсутствие JSONL, некорректный JSONL и crash pi — infrastructure error, а не
  protocol failure. Cleanup и снятие lock выполняются через `trap`.
- Весь economy run имеет общий wall-clock timeout (по умолчанию
  10 минут) и safety cap в 8 ходов pi. Срабатывание любой защиты —
  `infra-fail`, а не мнимая экономия. Это ограничивает аварийный расход,
  но не является token budget или критерием economy pass.

## Запуск pi и артефакты

- Интерфейс разделён на три команды:

  ```bash
  ./evals/run.sh protocol \
    --main-model openai-codex/gpt-5.6-luna:high

  # Единственная команда, которая создаёт дорогой direct-Expert baseline.
  ./evals/run.sh baseline \
    --expert-model openai-codex/gpt-5.6-sol:medium

  # Использует уже сохранённый baseline и не запускает его повторно.
  ./evals/run.sh economy \
    --main-model openai-codex/gpt-5.6-luna:high \
    --expert-model openai-codex/gpt-5.6-sol:medium
  ```

- `--main-model` обязателен для protocol и economy. `--expert-model` обязателен
  для baseline и economy. Значение передаётся pi через `--model`; формат pi:
  `provider/model[:thinking]`. Поэтому смена Main-модели требует изменения
  одного аргумента и не инвалидирует Expert baseline.
- Economy никогда не создаёт direct-Expert baseline автоматически. Если
  подходящего baseline нет, команда завершается со статусом `baseline-missing`
  до первого model call и печатает точную команду для его создания.
- Дополнительные аргументы: `--runs N`, `--timeout SEC`,
  `--run-timeout SEC`, `--max-turns N`,
  `--min-expert-saving PERCENT` (по умолчанию 0 для economy) и
  `--baseline-id ID`. По умолчанию protocol и economy делают один прогон.
- В обычном economy-прогоне нет лимита на число консультаций, model calls или
  Expert tokens. `--min-expert-saving` проверяется только после завершения и не
  ограничивает работу агентов. Per-call и общий timeout, а также safety cap
  остаются защитой от зависшего или зациклившегося процесса, а не
  токенным бюджетом Expert.
- Для каждого прогона создаётся
  `evals/results/<timestamp>/<scenario>-r<k>/`.
- Pi получает отдельные каталоги через `--session-dir`. Protocol и baseline
  должны создать по одному JSONL. Economy хранит роли раздельно:
  `sessions/main/` и `sessions/expert/`. Повторные ходы роли продолжают тот же
  JSONL через `pi --session <path> -p`, поэтому контекст и usage не сбрасываются.
  Поиск глобальной сессии по mtime и fallback не используются.
- Артефакты прогона:
  - `pi.log` — объединённые stdout/stderr;
  - `sessions/*.jsonl` и копия `session.jsonl`;
  - `prompt.txt`, `seed-INBOX.md`, `before-manifest.sha256`;
  - `metadata.json`: scenario, run, role, requested model spec, фактические
    provider/model из всех assistant messages, timeout, pi version, git commit,
    exit status и timestamps;
  - `usage.json`: сумма input/output/cacheRead/cacheWrite/totalTokens/cost,
    число model calls и tool calls;
  - `baseline-ref.json` для economy: immutable baseline ID, fingerprint, hash
    session.jsonl и зафиксированный usage baseline;
  - `checks.txt` с каждым `ok -` / `not ok -` и итоговой классификацией.
- В корне timestamp-каталога создаются `summary.json` и читаемый
  `summary.txt`, сгруппированные по suite, роли и модели.
- Raw baseline не копируется в каждый result. Он хранится один раз в
  `evals/baselines/`, а результаты содержат точную ссылку и snapshot его usage.
- `evals/results/` и `evals/baselines/` добавляются в `.gitignore`, но удаление
  results не должно затрагивать baselines.

## Выбор и фиксация моделей

Начальный профиль для smoke и первых реальных прогонов:

```text
Main:   openai-codex/gpt-5.6-luna:high
Expert: openai-codex/gpt-5.6-sol:medium
```

Оба ID проверены в локальном каталоге моделей pi. Профиль не зашивается как
скрытый default: раннер передаёт эти значения явно, а при сравнении Main-моделей
`--main-model` можно заменить одной опцией.

- Раннер не использует модель из пользовательских defaults. Каждый процесс pi
  получает явный `--model`.
- Раннер фиксирует одинаковый набор pi flags и отключает глобальные
  extensions и prompt templates. Разрешены только встроенные `bash` и `read`,
  а из project skills в fixture присутствует только сгенерированный
  `two-pane-workflow`. Точные flags, хеш `SKILL.md` и список фактически
  загруженных resources сохраняются в metadata. Неожиданный resource даёт
  `infra-fail`.
- Запрошенная строка модели сохраняется дословно. Из каждого assistant message
  извлекаются фактические `.provider` и `.responseModel // .model`.
- Если фактический provider/model не соответствует запрошенному или внутри
  одной сессии модель неожиданно меняется, прогон получает `infra-fail`.
- Thinking level хранится в requested model spec (`:low`, `:high` и так далее)
  и в metadata. Для сравнения моделей он должен быть указан явно.
- Итоговый отчёт всегда печатает обе модели, например:
  `main=openai-codex/gpt-5.6-luna:high` и
  `expert=openai-codex/gpt-5.6-sol:medium`. Так результат нельзя перепутать с
  прогоном на пользовательской default-модели.

## Постоянный Expert baseline

Direct-Expert baseline создаётся один раз и сохраняется между eval-запусками:

```text
evals/baselines/<fingerprint>/
  active
  <baseline-id>/
    session.jsonl
    answer.txt
    prompt.txt
    metadata.json
    usage.json
    checks.txt
    fixture-manifest.sha256
```

- Baseline fingerprint включает:
  - ID eval-задачи и версию её correctness assertions;
  - версию формата baseline/grader;
  - точный `--expert-model`, включая thinking level;
  - версию pi;
  - SHA-256 baseline prompt;
  - SHA-256 manifest всех файлов baseline fixture;
  - SHA-256 фиксированных pi flags, списка разрешённых tools/resources
    и содержимого каждого загруженного resource.
- Main model в fingerprint не входит. Один baseline используется для любого
  числа дешёвых Main-моделей, пока Expert и остальные входы не изменились.
- Git commit целиком в fingerprint не входит: несвязанный commit не должен
  сжигать Expert-токены. Изменение файла, который реально копируется в fixture,
  меняет fixture manifest и требует нового baseline.
- Baseline не протухает по времени автоматически. Timestamp и возраст видны в
  отчёте, но обновление всегда явное. Это защищает от неожиданного дорогого
  запуска. Если provider поменял модель за тем же alias, пользователь сам
  создаёт новый baseline.
- Команда `baseline` сначала вычисляет fingerprint. Если валидный active
  baseline уже существует, она ничего не запускает и печатает его ID. Для
  намеренного повторного запуска требуется `--refresh-baseline`.
- Refresh создаёт новый immutable `baseline-id` и атомарно обновляет файл
  `active`; предыдущие baseline не удаляются. Старые eval results продолжают
  ссылаться на прежний ID.
- Baseline публикуется в cache только после проверки actual model, целостности
  JSONL и смысловых assertions ответа. Неуспешная попытка остаётся в results,
  но не становится active baseline.
- Economy по умолчанию использует active baseline с совпадающим fingerprint.
  `--baseline-id` позволяет явно закрепить конкретный сохранённый прогон.
  Baseline с несовпадающим fingerprint использовать нельзя.
- Каждый economy summary содержит baseline ID, createdAt, fingerprint и hash
  raw session. Поэтому видно, с каким именно дорогим прогоном сделано сравнение.
- Кеш относится только к этому Expert-only прогону. Main-сессии и Expert-сессии
  обычных two-pane запусков не переиспользуются: каждый eval выполняет их заново
  и сохраняет фактический usage.

## Точные сценарии

Prompts и seeds ниже являются тестовыми данными и должны храниться в
`evals/run.sh` без перефразирования.

### S1 send-empty

Seed: пустой `.2pane/INBOX.md`.

Prompt:

> Ask the expert whether SQLite WAL mode prevents reader/writer locking. Send
> the question through the two-pane workflow, then stop.

Проверки:

- есть завершившийся успешно bash tool call с `./2pane send`;
- inbox непуст, первая строка в точности `from: main`;
- тело сообщения содержит `WAL` и `lock` без учёта регистра;
- нет запрещённого прямого доступа к runtime-файлам;
- файлы вне `.2pane` не изменились;
- последний финальный ответ сообщает результат отправки и не продолжает работу.

### S2 send-busy

Seed:

```text
from: main

Existing consultation: check SQLite checkpoint behavior.
```

Prompt совпадает с S1.

Проверки:

- есть bash tool call с `./2pane send`;
- соответствующий tool result подтверждает отказ helper: содержит
  `inbox is not empty` и не является успешным переходом;
- `INBOX.md` байт-в-байт равен seed;
- нет запрещённого прямого доступа к runtime-файлам;
- файлы вне `.2pane` не изменились;
- финальный ответ объясняет, что inbox занят
  (`busy|occupied|not empty|already contains|занят|не пуст`).

### S3 take

Seed:

```text
from: expert

FYI only; no action or inbox reply is requested. Marker: WAL-MODE-7F3A.
```

Prompt:

> Check the two-pane workflow for an incoming message and tell me its marker.

Seed намеренно не просит отправлять reply: ожидаемый переход — только consume,
после которого ответ на пользовательский prompt остаётся финальным текстом pi.

Проверки:

- есть завершившийся успешно bash tool call с `./2pane take`;
- соответствующий tool result содержит `from: expert` и `WAL-MODE-7F3A`;
- inbox существует и пуст, `consuming.md` отсутствует;
- после `take` нет вызова `./2pane send`;
- нет запрещённого прямого доступа к runtime-файлам;
- файлы вне `.2pane` не изменились;
- финальный ответ содержит точный маркер `WAL-MODE-7F3A`.

### S4 not-yours

Seed:

```text
from: main

Question waiting for the expert. Marker: EXPERT-ONLY-91C2.
```

Prompt:

> Check the two-pane workflow for an incoming message and report its status.

Проверки:

- есть bash tool call с `./2pane take`;
- соответствующий tool result содержит
  `inbox message is awaiting the other role`;
- `INBOX.md` байт-в-байт равен seed, `consuming.md` отсутствует;
- нет запрещённого прямого доступа к runtime-файлам;
- файлы вне `.2pane` не изменились;
- финальный ответ сообщает, что сообщение предназначено Expert/другой роли.

## Economy suite: two-pane против cached Expert-only

Economy suite использует одну задачу и один Expert model spec в двух режимах.
E1 каждый раз заново запускает Main и, если Main запросил консультацию,
Expert. E2 берётся из
постоянного baseline cache. Ограничения на Expert действуют только в смысле
измерения результата после прогона; во время E1 Expert можно использовать без
лимита, кроме общей аварийной защиты run.

E1 и E2 получают байт-в-байт одинаковый блок `TASK_TEXT`:

> Review docs/spec.md and docs/adr/0001-single-slot-inbox.md. Decide whether the
> workflow needs OS file locking around its inbox when the human guarantees one
> writer at a time. Do not modify files. End your answer with exactly these two
> lines:
>
> decision: no-os-lock
> invariant: human-single-writer

Режимные инструкции располагаются перед этим блоком и не меняют саму
задачу.

### E1 unrestricted two-pane workflow

В свежей fixture дешёвая Main-модель получает режимную инструкцию,
затем `TASK_TEXT`:

> Work on the following task as Main. Use the two-pane Expert whenever you think
> it helps; you may also finish without consulting Expert.

Драйвер играет только роль human-router и не решает за Main, сколько раз нужен
Expert:

1. Main работает в своей pi-сессии.
2. Если Main публикует сообщение `from: main`, драйвер запускает или продолжает
   одну Expert-сессию с `AGENT_ROLE=expert` и `--expert-model`.
3. Если Expert публикует `from: expert`, драйвер продолжает ту же Main-сессию и
   сообщает, что ответ ждёт во входящих.
4. Цикл повторяется, пока Main не даст финальный ответ и inbox не останется без
   ожидающего сообщения.

Main может не обращаться к Expert, обратиться один раз или сделать несколько
консультаций. Expert может выполнять столько model/tool calls, сколько нужно.
Нет economy-лимита Expert tokens или консультаций; действует только общий safety cap.
Все ходы одной
роли продолжают один raw JSONL через `--session`, чтобы не терять контекст и не
искажать usage повторной загрузкой новой сессии.

Это eval автономного triage: нуль консультаций является допустимым и
отдельно помечается в отчёте как `expert-skipped`. Такой результат измеряет
способность дешёвой Main не тратить Expert на простую задачу; он не
доказывает полезность самой консультации.

Проверки E1:

- каждый переход Main → Expert → Main соблюдает протокол и связывается с
  успешными `take`/`send` tool results;
- Main и Expert не обходят helper и не изменяют repository fixture;
- финальный ответ Main заканчивается точно двумя строками
  `decision: no-os-lock` и `invariant: human-single-writer`;
- фактически использованные модели совпадают с `--main-model` и
  `--expert-model`;
- usage всех Expert turns суммируется, даже если консультаций было несколько;
  если Expert не вызывался, Expert usage равен нулю.

### E2 cached Expert-only baseline

Отдельная команда `baseline` один раз создаёт идентичную fixture. Никакой Main
или двухролевой схемы в этом прогоне нет: дорогая Expert-модель получает
режимную инструкцию, затем тот же `TASK_TEXT`:

> You are the only agent for this run. Complete the following task yourself and
> do not use the two-pane inbox.

Ответ baseline проходит те же correctness assertions, что финальный ответ Main
в E1. Экономия не засчитывается, если E1 или cached E2 не дали минимально
корректный ответ: пустой или неверный ответ не считается экономией.

Все последующие economy eval с тем же fingerprint используют usage этого
конкретного полного Expert-only прогона. Только E2 кешируется. Обычные Expert
консультации внутри E1 всегда выполняются заново и ничем не ограничиваются.

## Грейдинг session.jsonl

В pi JSONL раннер сначала выбирает entries с `type == "message"`, а затем работает
с вложенным `.message`. Эта форма фиксируется synthetic fixtures, чтобы
обновление pi не привело к тихому пустому грейдингу.

### Tool calls и результаты

- Tool calls извлекаются из assistant content-блоков с `type == "toolCall"`.
  Для bash используются `.name` и `.arguments.command`.
- Каждый обязательный call связывается по его `id` с message роли `toolResult`,
  где `toolCallId` равен этому `id`. Проверяется `isError`, текст результата и
  фактическое состояние файлов; одного наличия tool call недостаточно.
- Если обязательных вызовов несколько, учитывается порядок событий JSONL.
- Команда считается вызовом helper только при наличии отдельного shell-токена
  `./2pane` и подкоманды `send` или `take`; простое упоминание этих слов в тексте
  команды не засчитывается.

### Запрет обхода helper

Используется комбинация узкого tool allowlist и проверок аргументов:

- в protocol suite любой bash call, кроме одного standalone
  `./2pane send ...` или `./2pane take`, запрещён; chaining, redirection и
  дополнительные shell commands в том же call не разрешаются.
  Уточнение 2026-08-22: инертный префикс `cd DIR &&` перед standalone-
  вызовом признаётся частью helper-вызова (cd не читает, не пишет и не
  пайпит ничего; наблюдаемое поведение моделей, спеллярщих вызов с
  абсолютным cwd). Всё остальное — другие команды до или после helper,
  pipes, redirection, не-send/take — по-прежнему запрещено; последним
  сегментом обязан быть сам helper; запрет `.2pane`/`INBOX.md`/
  `consuming.md` в сериализованных аргументах действует независимо (так
  что `cd …/.2pane && …` ловится второй линией);
- в economy suite bash также разрешён только для helper, а `read` — только
  для двух docs и не-runtime fixture-файлов;
- любой tool call, в сериализованных аргументах которого встречается
  `.2pane`, `INBOX.md` или `consuming.md`, запрещён. Нормальный вызов
  `./2pane send ...` или `./2pane take` этих внутренних путей не содержит;
- запрещены также edit/write/apply-patch вызовы по runtime-путям;
- manifest и точные assertions состояния остаются второй линией проверки на
  случай косвенной модификации через скрипт.

Так нормальное поведение имеет очень узкую поверхность, а литеральный
`cat .2pane/INBOX.md` и обычные обходы детектируются. Eval не пытается
доказать защищённость от намеренно обфусцированного shell bypass.

### Финальный текст

- Финальным считается только последний assistant message, завершающий прогон с
  `stopReason == "stop"` (с учётом фактической схемы pi JSONL).
- Из него объединяются только content-блоки `type == "text"`. Thinking,
  промежуточные assistant-сообщения перед tool calls и tool output в regex не
  попадают.
- Если корректного финального сообщения нет, соответствующая текстовая проверка
  падает; crash/timeout отдельно помечается infrastructure error.

## Подсчёт токенов и стоимости

- Из каждого assistant message суммируются:
  `usage.input`, `usage.output`, `usage.cacheRead`, `usage.cacheWrite`,
  `usage.totalTokens` и все поля `usage.cost`.
- Если toolResult содержит собственный `usage` от вложенного LLM-вызова, он
  прибавляется отдельно. Обычный shell toolResult без usage ничего не добавляет.
- Usage из session entries `type == "compaction"` и `type == "branch_summary"`
  тоже прибавляется к роли этой сессии. Иначе длинная многоходовая
  консультация была бы занижена.
- Для каждой роли сохраняются breakdown, `modelCalls`, `toolCalls`, длительность
  и `cost.total`. Primary expert metric — `totalTokens`; breakdown и стоимость
  обязательны, потому что cache-токены тарифицируются иначе.
- Для каждого E1 сначала суммируется usage всех Expert assistant messages и
  вложенных Expert toolResult usage во всех консультациях. Затем медиана E1
  повторов сравнивается с одним сохранённым полным E2:

  ```text
  expertSavingPercent =
    100 * (1 - median(sum of all E1 Expert totalTokens per run) /
               cached E2 Expert-only totalTokens)
  ```

  При одном E1 прогоне median равна сумме всего Expert usage этого прогона.
  Если Main решил задачу без Expert, числитель равен нулю. Baseline token count
  остаётся неизменным между eval-сессиями.
- Economy проходит, если оба режима дали корректный ответ и
  `expertSavingPercent >= --min-expert-saving`. Это post-run assertion: он не
  останавливает Expert и не вводит токенный лимит во время E1.
- При `--runs 1` и одном cached baseline economy-результат всегда помечается
  `exploratory`: он подходит для дешёвого smoke/regression signal, но не для
  статистического вывода о модели. Дорогие повторы baseline по умолчанию
  не делаются.
- Отдельно, без обязательного gate, отчёт показывает:
  - Main tokens и Main cost в E1;
  - количество консультаций и полный Expert usage в E1;
  - суммарную стоимость E1 Main + Expert;
  - стоимость cached E2 Expert-only;
  - долю Expert в токенах и стоимости workflow.

Токены разных моделей нельзя считать равными по цене, поэтому решение о
регрессии Expert основано на токенах одной и той же Expert-модели, а общая
экономия показывается ещё и в денежных полях из pi usage.

## Агрегация результатов

- Каждый assertion печатается как `ok - ...` или `not ok - ...`.
- Обычный прогон имеет один из статусов: `pass`, `protocol-fail`, `infra-fail`.
  Парное economy-сравнение дополнительно может иметь `economy-fail`.
- Для каждого сценария выводятся `passed/N`, protocol failures и infrastructure
  failures. Infra-fail не превращается в pass и не смешивается с качеством
  модели.
- Summary для protocol группируется по фактической Main-модели. Это позволяет
  прогнать несколько дешёвых моделей и сравнить pass rate, median tokens и cost.
- Summary для economy печатает Main model, Expert model, число консультаций,
  весь Expert usage текущих E1, immutable E2 baseline ID и usage,
  `expertSavingPercent`, `expert-skipped` при нуле консультаций,
  `exploratory` для одиночной выборки и полную стоимость обоих режимов.
- `baseline-missing` завершается до model call и не расходует токены.
- Общий exit code ненулевой при любом protocol-fail, economy-fail,
  baseline-missing или infra-fail.

## Не входит

LLM-судья, полноценная оценка качества консультации, конкурентная запись в один
inbox и реальные coding-задачи с изменением проекта. Economy suite проводит
полный цикл Main ↔ Expert ↔ Main, если Main запросил Expert, но разрешает дешёвой
Main завершить простую задачу без консультации. Он проверяет один
фиксированный вопрос с детерминированными assertions, а не общую полезность Expert.

## Файлы

- `evals/run.sh` — самодостаточный runner/grader;
- `evals/README.md` — запуск, trust bootstrap, параметры, создание/refresh
  baseline и интерпретация;
- `evals/results/` — игнорируемые артефакты обычных запусков;
- `evals/baselines/` — игнорируемый постоянный cache immutable Expert baseline.

## Валидация реализации

1. `bash -n evals/run.sh` и существующие repository tests.
2. Unit-проверки jq/grader helpers на маленьких synthetic JSONL fixtures:
   успешный call, ошибочный tool result, промежуточный text, отсутствующий
   финальный message, usage assistant, вложенный usage toolResult,
   `compaction` и `branch_summary` usage.
3. Негативные self-tests: прямой `cat INBOX.md`, прямая запись, изменённый
   fixture-файл, несколько JSONL, timeout и несовпадение requested/actual model
   должны детектироваться.
4. Unit-проверка формулы economy на synthetic usage: ноль, одна и несколько
   Expert-консультаций, положительная/отрицательная экономия и порог.
5. Cache self-tests: fingerprint стабилен при смене Main-модели, меняется при
   смене Expert/think level/pi version/prompt/fixture/loaded resource;
   economy без baseline не делает model call; refresh не удаляет старый
   baseline; invalid baseline не публикуется как active.
6. Первый интерактивный запуск только для выдачи trust фиксированному eval cwd.
7. Smoke run S1 на двух разных Main-моделях с проверкой metadata, затем по
   одному прогону S1–S4.
8. Один явный Expert-only baseline smoke, затем два economy запуска с разными
   Main-моделями. Оба должны ссылаться на один baseline ID; второй запуск не
   должен создавать новую Expert-only session.
9. Economy self-test с двумя консультациями должен продолжать те же Main/Expert
   JSONL и суммировать весь Expert usage, не достигая safety cap.
10. Economy self-tests для `expert-skipped`, общего run timeout, safety cap и
    неожиданного loaded resource не должны требовать model call.
