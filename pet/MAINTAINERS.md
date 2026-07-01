# 维护说明(for maintainers)

面向改代码的人。用户使用手册见 `README.md`。

## 文件清单(均在 `~/.claude/pet`)
| 文件 | 跑在 | 作用 |
| --- | --- | --- |
| `pet-resident.ps1` | **powershell.exe(5.1, STA)** | 常驻 GUI:分层透明宠物 + 状态卡 + 右键菜单 + 所有渲染/交互 |
| `pet-event.ps1` | **pwsh(7)** | 钩子→状态桥:`prompt/attention/done/busy/idle/end`,写 `sessions\<id>` |
| `pet-session-start.ps1` | pwsh(7) | SessionStart:登记本会话、按上次状态拉起宠物 |
| `pet-toggle.ps1` | pwsh(7) | `/my-pet` 开关,输出 ASCII `on`/`off` |
| `pet-sounds.ps1` | 任意 | 生成 `done.wav` / `attn.wav` |
| `claude-draw.ps1` | 任意 | 生成 `claude-idle/blink/happy.png` |
| `strings.json` | — | 多语种资源(加语言只需加一个块,含 `_name`) |

**运行时文件**:`lang.txt`(`auto/zh/en/ja`)、`sound.txt`(`on/off`)、`pet-state.txt`(开关记忆)、
`pet-pos.txt`(位置)、`pet.pid`、`sessions\<id>`(+`.dismiss` 关闭标记、`.titlelock` 改名锁定)。
命令:`~/.claude/commands/my-pet.md`;钩子:`~/.claude/settings.json` 的 `hooks`。

## 工作原理
- 钩子驱动状态(用户级 settings,所有会话/终端通用):`SessionStart`登记+拉起、`UserPromptSubmit`thinking+取首句标题、
  `PostToolUse`busy、`Stop`done、`Notification`attention(过滤空闲误报)、`SessionEnd`撤卡。
- 常驻每 ~300ms 读 `sessions\` 渲染卡片;每 60ms 跑动画;每 ~2s 查 `Get-Process claude`,无则自杀。
- 与终端无关:宠物是独立桌面进程,只认进程名 `claude.exe`,钩子在自己的 pwsh 里跑。

## 已落实的最佳实践
- 提示音:柔和正弦+指数衰减,两段多维可区分,**需确认 RMS 高于完成**,峰值 ≤ -12 dBFS。
- 勿扰/全屏抑制:`SHQueryUserNotificationState`(全屏/演示/专注助手时静音,卡片仍更新,fail-open)。
- 尊重减少动画:`SPI_GETCLIENTAREAANIMATION`(关动画→停浮动/眨眼、转圈转静态,每 3s 重查)。
- Per-Monitor DPI 感知;图标+颜色双编码;声音可一键静音(WCAG 1.4.2);需确认置顶;多语种即时切换。

## 踩过的坑(重要)
1. **5.1 编码**:常驻用 `powershell.exe`(WinForms 需 STA)。5.1 把无 BOM 的 UTF-8 当 GBK 读 →
   `pet-resident.ps1` **源码不能放中文/符号字面量**(「·」曾变「路」)。中文一律来自 `strings.json`/`sessions`
   (`[IO.File]::ReadAllText(path,UTF8)` 读),零散符号用 `[char]0xXXXX`。
2. **变量名大小写不敏感**:`$t`(行标签)曾覆盖 `$script:T`(语言对象)→ 别用单字母脚本级变量;i18n 用 `$script:STR`。
3. **pwsh vs powershell**:写文件/钩子用 pwsh(UTF-8);常驻 GUI 用 powershell.exe(STA)。
   `!` 捕获会弄乱中文 stdout → `pet-toggle.ps1` 只输出 ASCII `on/off`,中文由模型转述。
4. **权限**:`my-pet.md` 的 `allowed-tools` 必须匹配实际命令(`Bash(pwsh:*)`);settings 里精确放行 toggle(最小权限)。
5. **调试截图**:常驻是 Per-Monitor DPI 感知;截图进程也要设 DPI 感知,否则坐标对不上。
6. **沙箱**:`cmd /c` 可能被拦;喂 stdin 用 `Start-Process -RedirectStandardInput`。
7. 改脚本多数要**重启常驻**;钩子/命令改动要重启 Claude Code(或开一次 `/hooks`)才重载。
8. **SessionStart 会重复触发**(startup / resume / `/clear` / **compact**)。`pet-session-start.ps1` 不得无条件
   覆盖会话卡——否则压缩/恢复时会把已有的首句标题冲成项目名。规则:仅「新 sid」或 `/clear`(重置,
   顺带删 `.titlelock`)才写新 idle 卡;resume / compact / 重登记已有会话时**保持原卡不动**。同理
   `pet-event.ps1` 的 `idle`/`done`/`busy`/`attention` 用 `TitleOr`(保留已有标题),不要直接写 `$projOr`。

## 常用命令
```powershell
$d="$HOME\.claude\pet"
# 重启常驻
Get-Content "$d\pet.pid" | % { Stop-Process -Id $_ -Force -EA SilentlyContinue }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$d\pet-resident.ps1"
# 重新生成提示音 / 形象
& "$d\pet-sounds.ps1"; & "$d\claude-draw.ps1"
# 手动开关
pwsh -NoProfile -ExecutionPolicy Bypass -File "$d\pet-toggle.ps1"
```
