# 架构说明(ARCHITECTURE)

面向改代码的人:代码地图、工作原理、踩过的坑。用户使用手册见 `README.md`。

## 文件清单(脚本在插件安装目录,开发时即仓库 `pet\`;运行时数据在 `~/.claude/pet-data`)
| 文件 | 跑在 | 作用 |
| --- | --- | --- |
| `pet-resident.ps1` | **powershell.exe(5.1, STA)** | 常驻 GUI:分层透明宠物 + 状态卡 + 右键菜单 + 所有渲染/交互 |
| `pet-event.ps1` | **pwsh(7)** | 钩子→状态桥:`prompt/attention/done/busy/idle/end`,写 `sessions\<id>` |
| `pet-session-start.ps1` | pwsh(7) | SessionStart:登记本会话、按上次状态拉起宠物 |
| `pet-toggle.ps1` | pwsh(7) | `/my-pet` 开关,输出 ASCII `on`/`off` |
| `strings.json` | — | 多语种资源(加语言只需加一个块,含 `_name`) |

**开发工具**(仓库根 `tools/`,**不随插件发布**——marketplace `source:"./pet"` 只收 `pet/`;这些写入/校验 `pet/` 但自身不在其中):`pet-sounds.ps1`(生成 `done.wav`/`attn.wav`)、`claude-draw.ps1`(生成 `claude-idle/blink/happy.png`)、`guard-wt-tab-removed.ps1`(WT 删刀回归守卫 G1-G7,`pwsh tools/guard-wt-tab-removed.ps1`)。

**运行时文件**(均在 `~/.claude/pet-data`):`lang.txt`(`auto/zh/en/ja`)、`sound.txt`(`on/off`)、
`privacy.txt`(`on/off`;隐私模式:卡片正文打码为 cwd 项目名、详情清空)、`card-region.flag`(逃生阀:存在则强制回退旧 Region 卡;平滑分层卡自 v1.4.0 默认开,等价 env `PET_CARD_REGION=1`)、
`pet-state.txt`(开关记忆)、`pet-pos.txt`(位置)、`pet.pid`、`events.log`(调试,超 256KB 自动重建)、
`sessions\<id>`(+`.dismiss` 关闭标记、`.titlelock` 改名锁定、`.pending` 认命令布防:
`claudePid<TAB>armEpochMillis<TAB>归一化命令片段`,permreq 布防、其余事件拆防、常驻消费)、
`jump-req-<nonce>.json`(点卡握手请求,唯一名,60s 后由下次写入 GC)/`jump-ack.json`(VS Code 伴生扩展应答;两者都**在数据根目录不在 sessions\**——避开常驻 FSW;见最佳实践"tab 级跳转")。随附资产(`strings.json`/wav/png)由常驻
从插件目录镜像到这里;插件里的副本更新(mtime 变新)即自动覆盖刷新。
命令:插件自带 `commands/my-pet.md`(`/my-pet`);钩子:插件自带 `hooks/hooks.json`(路径经 `${CLAUDE_PLUGIN_ROOT}` 解析)。

## 工作原理
- 钩子驱动状态(插件 `hooks/hooks.json`,所有会话/终端通用):`SessionStart`登记+拉起+刷新 claudePid(第 7 字段)、`UserPromptSubmit`thinking+取首句标题、
  `PostToolUse`/`PostToolUseFailure`busy(工具跑完/失败即把 attention 复位;**不挂 PreToolUse**——它在权限弹窗**之前**触发,复位不了"需确认",
  只会让每次工具调用多一次 pwsh 冷启动,还把权限弹窗往后垫)、
  `PermissionRequest`attention(**即时**,`async` 后台跑不拖慢弹窗;命令类工具**顺带布防 `.pending`**,见下)、`PermissionDenied`busy(拒绝后你已不被需要)、
  `ElicitationResult`answered(问答弹窗被回答即把 attention 复位,同步防乱序)、
  `Stop`done、`Notification`attention(**兜底**——Claude Code 对权限通知有 6s 防打扰延迟,见坑 10;过滤空闲误报)、`SessionEnd`撤卡。
- 常驻用 FileSystemWatcher 即时感知 `sessions\` 变化(~120ms 轮询兜底)渲染卡片;每 60ms 跑动画;每 ~2s 查 `Get-Process claude`,无则自杀。
- 与终端无关:宠物是独立桌面进程,只认进程名 `claude.exe`,钩子在自己的 pwsh 里跑。

## 已落实的最佳实践
- 提示音:柔和正弦+指数衰减,两段多维可区分,**需确认 RMS 高于完成**,峰值 ≤ -12 dBFS。
- 勿扰/全屏抑制:`SHQueryUserNotificationState`(全屏/演示/专注助手时静音,卡片仍更新,fail-open)。
- 尊重减少动画:`SPI_GETCLIENTAREAANIMATION`(关动画→停浮动/眨眼、转圈转静态,每 3s 重查)。
- Per-Monitor DPI 感知;图标+颜色双编码;声音可一键静音(WCAG 1.4.2);需确认置顶;多语种即时切换。
- 单实例:常驻启动即持命名 Mutex(`ClaudePetResident`),SessionStart 并发竞态下第二个实例静默自退。
- PID 身份核验:toggle / session-start 先验证 `pet.pid` 指向的进程确为 `powershell` 且命令行含 `pet-resident.ps1`,
  才 Stop / 认定在跑——防崩溃/重启后 PID 被系统复用时误杀无关进程或误判"已在运行"。
- 资产随版本刷新:插件目录副本比 `pet-data` 副本新(mtime)即覆盖镜像,发新版改文案/音效对老用户生效。
- `events.log` 上限 256KB,超限重建,不无界增长。
- 溢出徽章(1.1.0):可显示会话(已剔除 × 关闭/闲置隐藏)超过 3 个时,第 3 行右下渲染静态灰字 `+N`
  (纯 ASCII,零 i18n 零交互);徽章可见时该行状态文本宽度收窄避让,溢出数进渲染签名 `sig`。
- 低延迟:"需确认"走 `PermissionRequest`(弹窗即触发)而非等 Notification 的 6s 防打扰;钩子写文件 →
  FileSystemWatcher 即刻渲染;纯观察且不怕乱序的钩子标 `async` 免拖慢主流程;钩子一律用 **exec 直启形式**
  (`command`+`args` 数组)——字符串 command 会先起一层 wrapper shell(Git Bash,实测 60-730ms)再启 pwsh,
  exec 形式把这层砍掉;剩余地板是 pwsh 冷启动(实测 ~0.6-1.2s,方差来自杀软)。
- **认命令翻卡(approved-command watch,1.0.10)**:批准权限后到工具跑完之间,Claude Code 依然
  不产生任何事件(2026-07-04 对 CC 2.1.200 全量 29 个钩子事件核验:无 "PermissionGranted";
  transcript 在批准时刻也零写入)。但**命令类工具的批准有系统级可观测后果**——那条命令会以
  claude.exe 子进程的形式出现,命令原文写在子进程 CommandLine 里(实测直接子进程、原文可见)。
  实现:permreq 把「归一化命令片段(≥6 字符,≤200)+ 父 claude PID + 布防时刻」写入
  `sessions\<id>.pending`;常驻仅在卡片为 attention 且有 `.pending` 时,每 1.2s 查一次该 PID 的
  子进程(CIM),**归一化 CommandLine 包含片段 + 出生时间晚于布防(容差 2s)+ 非 pet-event.ps1 自身**
  三条同时成立才翻回 thinking——是铁证不是猜。认不出(Edit 类无子进程、MCP 长调用、命令进临时脚本
  文件)一律不动,回落到 PostToolUse 复位,**宁可滞留绝不说谎**。归一化正则
  (去空白/引号/反斜杠/反引号)在 pet-event.ps1 与 pet-resident.ps1 **两处必须一致**。拆防:除
  permreq/attention 外的一切事件、`/clear`、7 天清理、以及翻卡本身都会删 `.pending`,杜绝陈旧
  片段日后误匹配。README 已知限制三语口径=命令类 1-2s 恢复,非命令类等跑完。
- **点卡跳窗(click-to-jump,1.2.0)**:会话记录第 7 字段 = claudePid(pet-event 每事件写入,捕获失败保留旧值不清空;
  SessionStart 对 resume/compact/老记录**只刷新该字段**,标题/状态/epoch 不动——坑 8 不回归)。单击卡片行的
  标题/状态文本 → 常驻从该 PID 沿父进程链上爬(≤8 层;祖先出生时间不得晚于子进程 +2s,防父 PID 被系统回收后
  指向陌生进程),命中第一个持真实顶层窗口的祖先(WT / VS Code / 独立控制台同一算法通吃)→ 最小化先还原 +
  `SetForegroundWindow`(点击宠物的瞬间本进程持前台授予,调用合法;失败兜底 AttachThreadInput 握手)。跳不了
  (PID 已死 / 被非 claude 进程复用 / 爬不到窗口 / 老 6 字段记录)→ 卡片横向摇头,**不跳不猜**;手型光标=可跳、
  默认光标=不可跳,affordance 不说谎。宠物自身只到窗口级;VS Code 内 tab 级由伴生扩展补全(见下条)。
  **WT 的 tab 级已调查后放弃、相关代码已删(2026-07-08)**:结构上不可行——WT 对外一律只见
  WindowsTerminal.exe、死不漏宿主 shell 的 PID(UIA 全树 ProcessId 全是 WT;AttachConsole+
  GetConsoleProcessList 不暴露 OpenConsole;`wt focus-tab` 只能按索引、无 pid→tab 映射),实测
  S-PID-INDEX 挂。故 WT 仅窗口级;要 tab 精度用 VS Code 或手动给 tab 改不同名。详见 4 份 Codex
  收敛稿 `docs/wt-tab-jump-{diagnosis-design,pid-investigation,solution-space}.md` + 删刀计划
  `docs/audits/2026-07-08-删WT-tab跳转.md`。(field 8 曾是 tab 指纹,现为空占位、不重编号。)
- **VS Code tab 级跳转 = 伴生扩展握手(1.3.0)**:纯外部无法聚焦 VS Code 内部终端面板(Electron 无障碍树
  不可靠、CLI 无命令口子),业界正解=自装扩展从内部干。常驻在**窗口级跳转成功后**把该会话的祖先 PID 链
  (Find-HostWindow 爬链的副产品,存 `$script:jumpChain`,预热时已填好 → 缓存命中的点击也拿得到)写入
  数据根目录 `jump-req-<nonce>.json`(**唯一名**:.tmp 写完 rename 到从不存在的终名,读端只认 *.json 故
  永不见半截;旧请求 60s 后 GC。初版用 `File.Replace($tmp,$dst,$null)` 踩中坑 13,连点必败已换);每个
  VS Code 窗口一个扩展实例 `fs.watch` 数据目录,只有"自己 `window.terminals` 的 `processId`(=集成终端
  shell 的 PID,即 claude 的父 pwsh)命中链中之一"的窗口才 `terminal.show(false)` 并回写 `jump-ack.json`
  ——**归属是 processId 证明出来的,不是按最顶窗口猜的**(vscode:// URI handler 的"topmost 窗口接收"语义
  被有意弃用,就因它与窗口激活存在时序 race)。`onStartupFinished` 在窗口(重)载后要滞后数秒才激活,
  空窗期的点击靠 activate 时**补扫最新仍新鲜的请求**兑现(仍受 5s 过期约束,不兑现陈旧点击)。
  请求 5s 过期 + nonce 去重,陈旧文件永不误翻;未装扩展则文件
  惰性,行为=纯窗口级(1.2.0),握手失败不得影响已完成的窗口跳转(Write-JumpRequest 全包 try,只回填
  events.log 的 `req=` 标志)。扩展源码在仓库顶层 `vscode-ext/claude-pet-jump/`(插件 payload 之外,纯 JS
  单文件零依赖);本地安装=整目录拷入 `~\.vscode\extensions\shin620265.claude-pet-jump-0.1.0` 后 Reload
  Window(T35/T36)。
- **分卡视觉+整行 hover(Region 卡,1.2.0)**——**⚠ v1.4.0 起平滑分层卡默认开,Region 卡降为 opt-out 兜底(`card-region.flag`/`PET_CARD_REGION=1`);以下描述遗留 Region 路径,分层卡机制见下方 card-layering 节**:每会话一个 Panel 容器(整行含空白皆是跳转命中区),窗体 Region=
  各行圆角矩形**并集**(行距 7px 缝隙从窗口裁掉,视觉即通知中心式独立卡,缝隙点击穿透);hover 采用**两级层级**
  区分行点击与行内图标(业界列表模式):整行**提亮为纯白**(底色是暖米白 250,249,245,白=变亮;压暗版被用户
  否掉)=「这张卡是一个大按钮」,✎/× 悬停各自出**底色背板**(✎ 灰块、× 浅红块+红字;8pt 小图标光换字色不可辨,
  背板才是 Chrome/VS Code 式图标 hover)=「行内独立小目标」;光标对行与图标都是手型(光标只表可点,不表做什么,
  与业界一致)。连带:editBox 是卡级兄弟控件,Edit-Row 需把标题的 panel 相对坐标换算回卡坐标;+N 徽章已改挂
  末行 Panel 内;hover 行计算含缝隙(缝隙=无 hover)。
- **跳窗延迟治理(1.2.0)**:Find-HostWindow 用**单次批量 CIM**(per-PID Filter 每跳 100-300ms,批量一次 ~0.5s
  内存爬链);解析结果进 `$script:jumpCache`(claudePid→HWND),常驻每 2s 预热一个未解析目标 → 首次点击即缓存
  命中(<50ms);失败也缓存 Zero(杜绝无谓重试),真实点击对 Zero 会兜底重爬一次;Activate 失败/IsWindow 失效
  即丢缓存重解析——缓存只加速,不改变"不跳不猜"语义(T33)。
- **hover 遮挡诚实(1.2.1)**:悬停行判定不能只做几何(Cursor.Position 在卡片矩形内)——右键菜单/任意窗口盖在
  卡片上时,纯几何会隔窗点亮珊瑚环,而点击根本到不了卡片(affordance 说谎,用户实测抓到)。必须加
  `WindowFromPoint`+`GetAncestor(GA_ROOT)`==card.Handle 顶层核验(T34)。图标 ✎/× 的 hover 走真实
  MouseEnter/Leave 消息,天然不穿窗,无需此守卫。
- 模型徽标**只在回合结束态(done/idle/interrupted)渲染**,回合中(thinking/attention)一律隐藏——正在跑的模型平台不暴露
  (钩子 payload 无 model 字段,settings 只有全局默认),显示"上一条的模型"会被读成"正在思考的模型"而误导。
- done 卡的 detail = **回复首句摘要**,与徽标取自 transcript(`transcript_path`)尾部**同一条** assistant 消息
  (同源:徽标标注的正是产出这段文字的模型);提取跳过 `isSidechain` 子代理条目与纯 tool_use 条目,只认
  `"model":"…"` JSON 字段防正文误匹配;提取失败回退 v1.0.6 行为(保留原 detail+正则取模型),事件缺
  transcript 时保留旧徽标;`/model` 切换后徽标随下一条回复自动跟上。

## 踩过的坑(重要)
1. **5.1 编码**:常驻跑在 `powershell.exe`(5.1)。(注:并非"WinForms 需 STA"所迫——pwsh 7 在 Windows 默认即 STA、也能跑 WinForms,2026-07-13 实测;此处旧说法已更正。)5.1 把无 BOM 的 UTF-8 当 GBK 读 →
   `pet-resident.ps1` **源码不能放中文/符号字面量**(「·」曾变「路」)。中文一律来自 `strings.json`/`sessions`
   (`[IO.File]::ReadAllText(path,UTF8)` 读),零散符号用 `[char]0xXXXX`。
2. **变量名大小写不敏感**:`$t`(行标签)曾覆盖 `$script:T`(语言对象)→ 别用单字母脚本级变量;i18n 用 `$script:STR`。
3. **pwsh vs powershell**:写文件/钩子用 pwsh(UTF-8);常驻 GUI 用 powershell.exe(5.1)。
   `!` 捕获会弄乱中文 stdout → `pet-toggle.ps1` 只输出 ASCII `on/off`,中文由模型转述。
4. **权限**:`my-pet.md` 的 `allowed-tools` 必须匹配实际命令(`Bash(pwsh:*)`),保持最小权限。
5. **调试截图**:常驻是 Per-Monitor DPI 感知;截图进程也要设 DPI 感知,否则坐标对不上。
6. **沙箱**:`cmd /c` 可能被拦;喂 stdin 用 `Start-Process -RedirectStandardInput`。
7. 改脚本多数要**重启常驻**;钩子/命令改动要重启 Claude Code(或开一次 `/hooks`)才重载。
8. **SessionStart 会重复触发**(startup / resume / `/clear` / **compact**)。`pet-session-start.ps1` 不得无条件
   覆盖会话卡——否则压缩/恢复时会把已有的首句标题冲成项目名。规则:仅「新 sid」或 `/clear`(重置,
   顺带删 `.titlelock`)才写新 idle 卡;resume / compact / 重登记已有会话时**保持原卡不动**。同理
   `pet-event.ps1` 的 `idle`/`done`/`busy`/`attention` 用 `TitleOr`(保留已有标题),不要直接写 `$projOr`。
9. **PreToolUse 在权限弹窗"之前"触发**(所以钩子才能代替用户放行/拦截),别指望它把 attention 复位——
   复位"需确认→思考中"的路径只有两条:`PostToolUse`/`PostToolUseFailure`(工具跑完/失败,兜底、
   对一切工具生效)+ 常驻认命令翻卡(1.0.10,仅命令类,见最佳实践)。1.0.2 曾删错钩子(留 Pre 删 Post),
   导致用户批准后卡片长时间滞留"需要你确认/选择",1.0.3 修正。
10. **Notification 的权限通知天生慢 6 秒**:Claude Code 源码里权限弹窗挂载后要等 `ZTc=6000ms`(防打扰,
    6 秒内已响应则不发,不可配置)才发 Notification。"需确认"的即时性靠 `PermissionRequest` 钩子(弹窗即触发,
    1.0.4 引入);Notification 仅作兜底,两者写同一 key,幂等不重响。`async` 只用于纯观察钩子——
    `done`/`busy` 这类有先后语义的保持同步,防止乱序覆盖(如 Stop 的 done 被迟到的 busy 冲掉)。
11. **周期性置顶重申必须避开一切瞬态 UI**:每 ~2s 的 `SetWindowPos(TOPMOST)` 会把卡片砸到置顶层最上方,
    盖住同层的弹出物。改名编辑框早有守卫(`$script:editing`),右键菜单漏了——1.0.8 补 `-not $menu.Visible`,
    并把菜单改为 owner 形式弹出(`$menu.Show($form,…)`,owned popup 恒在 owner 之上)。以后新增任何
    菜单/tooltip/浮层,都要同步扩这个守卫。
12. **PS 5.1 把 `$null` 塞给 .NET 的 [string] 参数会变空字符串**:`[IO.File]::Replace($tmp,$dst,$null)`
    的"不留备份"用法($null 只是第三参的约定值;Replace 两个重载**都**强制要备份路径参数,**没有**
    无备份重载)因此必炸 "The path is not of a legal form"(空串不是合法路径)——首测偶尔通过纯属
    目标文件恰好不存在走了 Move-Item 分支,连点第二下即败。凡 .NET API 的可空 string 参数:换不含该参
    的重载(若该 API 真提供——`File.Replace` 就不提供)、传 `[NullString]::Value`,或干脆改用不需要
    空值语义的方案(跳转握手最终用唯一文件名 rename)。
13. **展示过期 ≠ 数据删除**:TTL 曾"过期即删",把首句标题和 `.titlelock` 改名一并冲掉——会话复活后
    标题变成最新输入,违反自家坑 8 的"用户标题不可冲"原则。1.0.9 拆成两层:30 分钟只**隐藏**
    (跳过渲染,文件保留),7 天才物理删除;`SessionEnd` 从删文件改为**把 epoch 拨老**(立即隐藏但保留记忆,
    `claude --resume` 回来改名仍在);`/clear` 仍按设计重置标题。不许回退成"过期即删"。

## 常用命令
```powershell
$data="$HOME\.claude\pet-data"        # 运行时数据
$code="<插件安装目录或仓库 pet 目录>"   # 脚本所在
# 重启常驻
Get-Content "$data\pet.pid" | % { Stop-Process -Id $_ -Force -EA SilentlyContinue }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$code\pet-resident.ps1"
# 重新生成提示音 / 形象(dev 工具在仓库 tools/,写入 pet/,常驻启动时按 mtime 镜像到 $data)
& "$code\..\tools\pet-sounds.ps1"; & "$code\..\tools\claude-draw.ps1"
# 手动开关
pwsh -NoProfile -ExecutionPolicy Bypass -File "$code\pet-toggle.ps1"
```
