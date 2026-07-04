# 维护说明(for maintainers)

面向改代码的人。用户使用手册见 `README.md`。

## 文件清单(脚本在插件安装目录,开发时即仓库 `pet\`;运行时数据在 `~/.claude/pet-data`)
| 文件 | 跑在 | 作用 |
| --- | --- | --- |
| `pet-resident.ps1` | **powershell.exe(5.1, STA)** | 常驻 GUI:分层透明宠物 + 状态卡 + 右键菜单 + 所有渲染/交互 |
| `pet-event.ps1` | **pwsh(7)** | 钩子→状态桥:`prompt/attention/done/busy/idle/end`,写 `sessions\<id>` |
| `pet-session-start.ps1` | pwsh(7) | SessionStart:登记本会话、按上次状态拉起宠物 |
| `pet-toggle.ps1` | pwsh(7) | `/my-pet` 开关,输出 ASCII `on`/`off` |
| `pet-sounds.ps1` | 任意 | 生成 `done.wav` / `attn.wav` |
| `claude-draw.ps1` | 任意 | 生成 `claude-idle/blink/happy.png` |
| `strings.json` | — | 多语种资源(加语言只需加一个块,含 `_name`) |

**运行时文件**(均在 `~/.claude/pet-data`):`lang.txt`(`auto/zh/en/ja`)、`sound.txt`(`on/off`)、
`pet-state.txt`(开关记忆)、`pet-pos.txt`(位置)、`pet.pid`、`events.log`(调试,超 256KB 自动重建)、
`sessions\<id>`(+`.dismiss` 关闭标记、`.titlelock` 改名锁定、`.pending` 认命令布防:
`claudePid<TAB>armEpochMillis<TAB>归一化命令片段`,permreq 布防、其余事件拆防、常驻消费)。随附资产(`strings.json`/wav/png)由常驻
从插件目录镜像到这里;插件里的副本更新(mtime 变新)即自动覆盖刷新。
命令:插件自带 `commands/my-pet.md`(`/my-pet`);钩子:插件自带 `hooks/hooks.json`(路径经 `${CLAUDE_PLUGIN_ROOT}` 解析)。

## 工作原理
- 钩子驱动状态(插件 `hooks/hooks.json`,所有会话/终端通用):`SessionStart`登记+拉起、`UserPromptSubmit`thinking+取首句标题、
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
- 模型徽标**只在回合结束态(done/idle)渲染**,回合中(thinking/attention)一律隐藏——正在跑的模型平台不暴露
  (钩子 payload 无 model 字段,settings 只有全局默认),显示"上一条的模型"会被读成"正在思考的模型"而误导。
- done 卡的 detail = **回复首句摘要**,与徽标取自 transcript(`transcript_path`)尾部**同一条** assistant 消息
  (同源:徽标标注的正是产出这段文字的模型);提取跳过 `isSidechain` 子代理条目与纯 tool_use 条目,只认
  `"model":"…"` JSON 字段防正文误匹配;提取失败回退 v1.0.6 行为(保留原 detail+正则取模型),事件缺
  transcript 时保留旧徽标;`/model` 切换后徽标随下一条回复自动跟上。

## 踩过的坑(重要)
1. **5.1 编码**:常驻用 `powershell.exe`(WinForms 需 STA)。5.1 把无 BOM 的 UTF-8 当 GBK 读 →
   `pet-resident.ps1` **源码不能放中文/符号字面量**(「·」曾变「路」)。中文一律来自 `strings.json`/`sessions`
   (`[IO.File]::ReadAllText(path,UTF8)` 读),零散符号用 `[char]0xXXXX`。
2. **变量名大小写不敏感**:`$t`(行标签)曾覆盖 `$script:T`(语言对象)→ 别用单字母脚本级变量;i18n 用 `$script:STR`。
3. **pwsh vs powershell**:写文件/钩子用 pwsh(UTF-8);常驻 GUI 用 powershell.exe(STA)。
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
12. **展示过期 ≠ 数据删除**:TTL 曾"过期即删",把首句标题和 `.titlelock` 改名一并冲掉——会话复活后
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
# 重新生成提示音 / 形象(写入 $code,常驻启动时按 mtime 镜像到 $data)
& "$code\pet-sounds.ps1"; & "$code\claude-draw.ps1"
# 手动开关
pwsh -NoProfile -ExecutionPolicy Bypass -File "$code\pet-toggle.ps1"
```
