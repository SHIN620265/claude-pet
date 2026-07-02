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
`sessions\<id>`(+`.dismiss` 关闭标记、`.titlelock` 改名锁定)。随附资产(`strings.json`/wav/png)由常驻
从插件目录镜像到这里;插件里的副本更新(mtime 变新)即自动覆盖刷新。
命令:插件自带 `commands/my-pet.md`(`/my-pet`);钩子:插件自带 `hooks/hooks.json`(路径经 `${CLAUDE_PLUGIN_ROOT}` 解析)。

## 工作原理
- 钩子驱动状态(插件 `hooks/hooks.json`,所有会话/终端通用):`SessionStart`登记+拉起、`UserPromptSubmit`thinking+取首句标题、
  `PostToolUse`busy(工具跑完即把 attention 复位;**不挂 PreToolUse**——它在权限弹窗**之前**触发,复位不了"需确认",
  只会让每次工具调用多一次 pwsh 冷启动,还把权限弹窗往后垫)、
  `PermissionRequest`attention(**即时**,`async` 后台跑不拖慢弹窗)、`PermissionDenied`busy(拒绝后你已不被需要)、
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
- 低延迟:"需确认"走 `PermissionRequest`(弹窗即触发)而非等 Notification 的 6s 防打扰;钩子写文件 →
  FileSystemWatcher 即刻渲染;纯观察且不怕乱序的钩子标 `async` 免拖慢主流程;钩子一律用 **exec 直启形式**
  (`command`+`args` 数组)——字符串 command 会先起一层 wrapper shell(Git Bash,实测 60-730ms)再启 pwsh,
  exec 形式把这层砍掉;剩余地板是 pwsh 冷启动(实测 ~0.6-1.2s,方差来自杀软)。
- 模型徽标语义是**"该会话上一条回复的模型"**,不是"当前模型"——钩子 payload 不含 model 字段,settings 里只有
  全局默认(多会话会张冠李戴),唯一每会话真实来源是 transcript(`transcript_path`)尾部最后一个
  `"model":"…"` JSON 字段(只认 JSON 字段、不匹配正文自由文本,防止对话内容里提到的模型 ID 误入);
  `/model` 切换后徽标随下一条 assistant 消息自动跟上,事件缺 transcript 时保留旧徽标。

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
   复位"需确认→思考中"的只能是 `PostToolUse`(工具跑完)。1.0.2 曾删错钩子(留 Pre 删 Post),
   导致用户批准后卡片长时间滞留"需要你确认/选择",1.0.3 修正。
10. **Notification 的权限通知天生慢 6 秒**:Claude Code 源码里权限弹窗挂载后要等 `ZTc=6000ms`(防打扰,
    6 秒内已响应则不发,不可配置)才发 Notification。"需确认"的即时性靠 `PermissionRequest` 钩子(弹窗即触发,
    1.0.4 引入);Notification 仅作兜底,两者写同一 key,幂等不重响。`async` 只用于纯观察钩子——
    `done`/`busy` 这类有先后语义的保持同步,防止乱序覆盖(如 Stop 的 done 被迟到的 busy 冲掉)。

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
