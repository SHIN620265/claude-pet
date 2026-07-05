# 测试交接 Prompt —— Claude 桌面宠物(给 reviewer)

> 把本文件整篇交给 reviewer(人或另一个 Claude Code agent)。它是自包含的:照着做即可系统化验证这个应用。

---

## 0. 你的角色与目标
你是这个 **Windows 桌面常驻宠物 + Claude Code 会话提醒**应用的**测试/复核方**。目标:
1. 逐项验证功能、健壮性、是否符合既定的最佳实践;
2. 每项给出 **通过/失败 + 证据**(命令输出 / 截图 / 测量值);失败要给**最小复现**;
3. 复核"历史坑"是否回归(见 §5);
4. 全程**只测不改**;若发现 bug,报告给负责人,不要擅自改实现。

脚本目录(下称 `$code`):插件安装目录,开发时即本仓库 `pet\`;运行时数据目录(下称 `$data`):`~/.claude/pet-data`

---

## 1. 先读这两份
- `README.md` —— 用户手册(三语),理解功能与交互。
- `MAINTAINERS.md` —— 架构、文件清单、工作原理、踩过的坑。

---

## 2. 环境硬约束(测错的根源,务必先懂)
- **常驻 `pet-resident.ps1` 跑在 `powershell.exe`(5.1, STA)**;钩子脚本跑在 `pwsh`(7)。WinForms 必须 STA。
- **5.1 编码坑**:5.1 把无 BOM 的 UTF-8 当 GBK 读 → 常驻源码**不能有中文/符号字面量**。所有中文来自 `strings.json` / `sessions` 文件(UTF-8 读)或 `[char]0xXXXX`。看到卡片/菜单乱码 = 这条破了。
- **DPI**:常驻是 Per-Monitor DPI 感知。**你的截图进程也必须设 DPI 感知**,否则坐标对不上(见 §3 片段)。
- **单实例**:常驻启动即持命名 Mutex(`ClaudePetResident`),`pet.pid` 记录当前常驻 PID。理论上不会再出现"两个常驻叠加"(历史上踩过);若见到即回归失败(T16)。
- **沙箱**:`cmd /c` 可能被拦;给子进程喂 stdin 用管道或 `Start-Process -RedirectStandardInput`。
- **会话状态文件格式**(`sessions\<id>`,单行,TAB 分隔):
  `key <TAB> label <TAB> title <TAB> detail <TAB> epochMillis <TAB> model`
  - `key` ∈ `thinking|attention|done|idle`(决定颜色/图标/本地化文案);`label` 已被常驻忽略(按 key 本地化),填占位即可;`title`=卡片标题;`detail`=状态行后半句(思考/需确认时=你最近一句输入,**done 时=回复首句摘要**);`model`(可空)=该会话上一条回复的模型短名(如 `Fable 5`),**仅在 done/idle 态**渲染为状态行前缀,老格式(5 字段)兼容。
  - 侧车 `sessions\<id>.pending`(认命令布防,单行 TAB 分隔):`claudePid <TAB> armEpochMillis <TAB> 归一化命令片段`。permreq 布防;其余事件/翻卡/`/clear`/7 天清理拆防。

---

## 3. 可复用片段(直接抄)

**变量约定(以下片段通用)**
```powershell
$data="$HOME\.claude\pet-data"        # 运行时数据
$code="<插件安装目录或仓库 pet 目录>"   # 脚本所在
```

**重启常驻**
```powershell
Get-Content "$data\pet.pid" | % { Stop-Process -Id $_ -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 600
$p=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$code\pet-resident.ps1"
$p.Id | Set-Content "$data\pet.pid"; Start-Sleep -Seconds 3
"alive=$(-not $p.HasExited)"
```

**注入一个会话状态(模拟某会话进入某状态)**
```powershell
$sd="$HOME\.claude\pet-data\sessions"; $e=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
[IO.File]::WriteAllText("$sd\t_attn", ("attention`tX`t测试标题`t最近一句输入`t$e"), (New-Object Text.UTF8Encoding($false)))
# 用完删:Remove-Item "$sd\t_*" -Force
```

**触发一个真实钩子(带 stdin JSON,UTF-8)**
```powershell
'{"session_id":"t_hook","cwd":"D:\\path\\myproject","prompt":"做一个功能"}' | pwsh -NoProfile -ExecutionPolicy Bypass -File "$code\pet-event.ps1" prompt
# 其它事件:done / busy(PostToolUse/PostToolUseFailure/PermissionDenied)/ permreq(PermissionRequest,即时 attention+命令类布防 .pending)/ answered(ElicitationResult,复位 attention)/ attention(Notification 兜底,需 message/type)/ idle / end
# SessionStart:把 source 设 compact/clear/startup 测标题保留/重置
'{"session_id":"t_hook","cwd":"D:\\path\\myproject","source":"compact"}' | pwsh -NoProfile -File "$code\pet-session-start.ps1"
```

**DPI 感知截图(卡片区域)**
```powershell
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class D{ [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);}
"@
[D]::SetProcessDpiAwarenessContext([IntPtr](-4))|Out-Null
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$pos=(Get-Content "$data\pet-pos.txt") -split ','; $px=[int]$pos[0]; $py=[int]$pos[1]
$x=$px-95; $y=$py+150   # 卡片大致在宠物左下
$bmp=New-Object System.Drawing.Bitmap 480,200; $g=[System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($x,$y,0,0,(New-Object System.Drawing.Size(480,200))); $bmp.Save("$env:TEMP\pet-shot.png"); $g.Dispose(); $bmp.Dispose()
# 再用读图工具看 $env:TEMP\pet-shot.png
```

**量提示音(peak/RMS,dBFS)**
```powershell
function MW($p){ $b=[IO.File]::ReadAllBytes($p); $n=([double]($b.Length-44))/2; $s=0.0; $pk=0
 for($i=44;$i -lt $b.Length-1;$i+=2){ $v=[BitConverter]::ToInt16($b,$i); $a=[math]::Abs($v); if($a -gt $pk){$pk=$a}; $s+=[double]$v*$v }
 "{0}: peak={1:N2} RMS={2:N2} dur={3:N0}ms" -f (Split-Path $p -Leaf),(20*[math]::Log10($pk/32768)),(20*[math]::Log10([math]::Sqrt($s/$n)/32768)),($n/44100*1000) }
MW "$HOME\.claude\pet-data\done.wav"; MW "$HOME\.claude\pet-data\attn.wav"
```

**读系统状态(用于声音抑制 / 减少动画测试)**
```powershell
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class Q{
 [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int s);
 [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a,uint b,ref int c,uint d);
 public static int NS(){int s=0;SHQueryUserNotificationState(out s);return s;}
 public static int AN(){int v=1;SystemParametersInfo(0x1042,0,ref v,0);return v;} }
"@
"notif state=$([Q]::NS()) (5=可通知)  animations=$([Q]::AN()) (1=开/0=减少)"
```

---

## 4. 测试矩阵(逐项:做什么 / 怎么测 / 通过标准)

| # | 项 | 怎么测 | 通过标准 |
|---|---|---|---|
| T1 | 生命周期-出现/消失 | 关掉全部 `claude.exe` 看宠物是否消失;再开一个看是否按 `pet-state.txt` 恢复 | 无 claude.exe→常驻 ~2s 内退出;有→按上次状态恢复 |
| T2 | `/my-pet` 开关 | 跑 `pet-toggle.ps1` 两次 | 输出 `off` 再 `on`(纯 ASCII);`pet-state.txt` 同步;进程随之关/开 |
| T3 | 卡片状态×4 | 分别注入 `thinking/attention/done/idle`,截图 | 颜色+图标正确:思考蓝转圈 / 完成绿✓ / 需确认琥珀! / 空闲灰;状态行=状态·detail |
| T4 | 多卡叠放+置顶排序 | 注入 3+ 会话,其中一个最旧的设 `attention` | 同屏≤3 张;`attention` 浮到最顶,其余按时间(新→旧) |
| T5 | 标题=首句+改名锁 | 触发 `prompt` 首句→看标题;点 ✎ 改名;再触发 `prompt` | 标题=首句;改名后写 `.titlelock`,后续不被覆盖 |
| T6 | 标题不被 compact 冲 | 注入带真实标题的会话→`session-start source=compact` | 标题**保留**(不变项目名);`source=clear`→重置为项目名/新会话 |
| T7 | × 关闭+复现 | 点某行 ×;再给该会话注入新状态 | × 后该卡消失;有新动静自动复现 |
| T8 | 提示音 | 见 §3 量 wav;触发 done/attention 听 | `attn` RMS > `done` RMS(约 +3dB);两者 peak ≤ -12dBFS;转换时播放;**重启首轮静音** |
| T9 | 提示音开关 | 右键「提示音」切;或改 `sound.txt` | 关后 done/attention 不出声但卡片仍更新;`sound.txt` 持久 |
| T10 | 勿扰/全屏抑制 | 进入全屏/演示(`[Q]::NS()`≠5)时触发 done | 不出声(卡片仍更新);恢复(NS=5)后正常 |
| T11 | 减少动画 | 关 Windows 动画(设置→辅助功能→视觉效果→动画效果),`[Q]::AN()`=0 | 宠物停浮动/眨眼;转圈变静态「…」;开回动画恢复(≤3s) |
| T12 | 置顶不被压 | 见 §3 末"找宠物窗口并踩到底层"片段 | 被降级后 ≤2s 自动重新置顶;但 NS≠5 时不强抢 |
| T13 | 多语种 | `lang.txt` 设 zh/en/ja/auto 重启;右键「语言」即时切 | 状态/菜单本地化正确;卡片标题(你的输入)**不翻译**;auto 跟随系统 |
| T14 | 钩子映射 | 逐个触发 prompt/busy/done/attention/idle/end/answered(busy=PostToolUse+PostToolUseFailure,answered=ElicitationResult;hooks.json 不得含 PreToolUse) | 状态正确流转;answered 仅在当前为 attention 时复位为 thinking;`waiting for`/idle_prompt/auth_success/elicitation_* 被过滤不弹 |
| T15 | 编码 | 看菜单「关闭宠物」「·」分隔、中文卡片 | 无乱码(无「路」等) |
| T16 | 单实例(Mutex) | 直接**并发**启动 2 个 `pet-resident.ps1`(或先删常驻再并发 2 次 SessionStart) | ~3s 后只剩 1 个 `pet-resident.ps1` 进程,第二个静默自退 |
| T17 | 多界面并存 | 在 WT/VS Code 终端/PowerShell 同时开 Claude | 各自一张卡;任一 claude.exe 在即不退 |
| T18 | (发布前)可移植性 | 全仓搜 `C:\Users\` 一类写死绝对路径 | 报告所有写死的绝对路径(应为 `$PSScriptRoot`/`$env:USERPROFILE`) |
| T19 | PID 复用安全 | 起一个无关 `powershell -Command Start-Sleep 60`,把它的 PID 写入 `$data\pet.pid`,跑 `pet-toggle.ps1` | 无关进程**不被杀**;toggle 视为"未运行",输出 `on` 并拉起新宠物 |
| T20 | 资产随版本刷新 | `(Get-Item "$code\strings.json").LastWriteTime = Get-Date`,重启常驻 | `$data\strings.json` 被覆盖(mtime 变新);内容与 `$code` 一致 |
| T21 | 低延迟(FSW) | 注入一个 attention 会话文件,立即截图 | 卡片近即时更新(≤0.5s,FileSystemWatcher;120ms 轮询仅兜底) |
| T22 | 即时"需确认"(PermissionRequest) | 真实触发一个权限弹窗,掐表看卡片变琥珀 | ≤1.5s(不等 Notification 的 6s 防打扰);被 allowlist 自动放行的命令**不得**出 attention 卡;6s 后 Notification 兜底到来不得重响提示音。批准后的恢复见 T27 |
| T23 | 模型徽标(仅回合结束态) | 注入带 model 字段的 done / thinking / attention 卡各一张;再注入 5 字段老格式卡 | done 卡显示 `Fable 5 · 已完成 · …`;thinking/attention 卡**不显示**徽标(即使 model 字段有值);老格式卡不报错;无 transcript 的事件(如 permreq)保留已有徽标字段 |
| T24 | 完成卡=回复摘要(同源) | 造假 transcript:主线 assistant(text+model)在前、`isSidechain:true` 条目在后、结尾再放纯 tool_use 条目,触发 `done` | detail=主线回复首句(剥 markdown、截 60);model 与该条**同源**;sidechain 与 tool_use 条目被跳过;把 text 块全删再触发 `done` → 回退保留原 detail/model;正文提到的模型 ID 不得干扰 |
| T25 | 菜单不被卡片遮挡 | 有卡片显示时右键宠物打开菜单,保持打开 ≥5s(跨越 ≥2 个置顶重申周期) | 菜单全程完整可见、不被卡片压住;菜单关闭后 ≤2s 置顶重申恢复(T12 不回归) |
| T26 | 标题跨隐藏/退出存活 | ①改名后把 epoch 拨老 31 分钟;②触发 `end` 再触发新 `prompt`;③把 epoch 拨老 8 天 | ①卡片隐藏但文件与 `.titlelock` 仍在;②`end` 后文件保留(key=idle,epoch 已拨老),新 prompt 复活后标题=改名(未改名则=最初首句,**不得**变成最新输入);③下个轮询周期文件被物理清除(含 `.pending`) |
| T27 | 认命令翻卡(批准即恢复) | ①真实批准一条长命令(如 `ping -n 20 127.0.0.1`),掐表;②真实**拒绝**一条命令;③批准非命令类(如 Edit);负向守卫用注入法:起一个假父进程,写 attention 卡+`.pending` 指向它(格式见 §2),分别令 a)子进程命令与片段不符 b)子进程先于布防出生(拨老 arm 前先起子进程) | ①批准后 ≤2.5s 卡片翻回"正在思考",`.pending` 被消费;②拒绝→busy 复位且 `.pending` 被清;③无子进程可认,保持琥珀直至 PostToolUse(**非回归**);负向 a/b 均**不得**翻卡(翻了=说谎回归);permreq 对无 command 字段/命令 <6 字符的工具**不布防** |
| T28 | +N 溢出徽章 | **重启常驻前**注入 5+ 个 thinking 会话(避免重响),数一下当时可显示会话总数 E;截图;再删到 E≤3 截图 | 第 3 行右下出现灰色 `+(E-3)`,不遮挡状态文本、不响、不可点;E≤3 时徽章消失、卡高随行数收缩;× 关闭与闲置隐藏的会话**不计入** N |
| T29 | 点卡跳窗(窗口级) | 先把宿主窗口切到后台(聚焦浏览器等其它应用),单击真实会话卡片行的标题或状态文本;再把宿主窗口**最小化**重复一次 | 宿主窗口(WT / VS Code / 控制台)被拉到前台,最小化时先还原再前置;行光标为手型;`events.log` 出现 `jump ... ok=1`;×/✎/宠物拖动行为不受影响 |
| T30 | 跳窗诚实兜底(负向) | ①注入第 7 字段=不存在 PID 的卡;②注入第 7 字段=某无关**非 claude** 进程 PID 的卡(如 Start-Sleep 的 powershell);③注入 6 字段老格式卡 | ①②单击→卡片横向摇头、**不得**激活任何窗口(激活了=指鹿为马回归),log `ok=0`;③行光标为**默认**(非手型),单击同样摇头不崩溃;该会话下个真实事件后第 7 字段自愈、光标变手型 |
| T31 | PID 随 resume 跟车 | `end` 一个会话后,在**新终端窗口** `claude --resume <会话id>` 打开它 | SessionStart 只刷新第 7 字段=新 claude PID,标题/epoch/状态原样(T6 不回归);单击卡片跳到**新**窗口而非旧窗口 |
| T32 | 分卡+整行 hover(1.2.0 视觉) | 注入 3 张卡截图;鼠标悬停中间行截图;再分别悬停 ✎ 与 ×;把光标停在两卡**间隙**;单击行内**空白处**(非文字非图标) | 每会话独立圆角卡、卡间 ~7px 真空隙(透出桌面,点击穿透);hover 行=**杏白底(254,240,233)+2px 珊瑚描边环(217,119,87,随卡片圆角)**——浮动卡在任意壁纸上,靠 focus-ring 式边缘线索而非亮度(纯白/暖灰细线两版均已被实测否决)、移开恢复,间隙处不算 hover;✎ 悬停出灰底块、× 悬停出浅红底块+红字(图标有自己的背板,与整行区分);行内空白处单击也跳转;+N 徽章仍在第 3 卡右下不遮字(T28 连带);✎ 改名框仍对齐标题(T5 连带);双击宠物收起/展开不回归 |
| T33 | 跳窗低延迟(缓存+预热) | 卡片出现后等 ≥3s(预热窗口)再首次点击,掐表;紧接着二次点击同一行 | 首次点击即近即时(≤0.3s,预热缓存命中,log `cache=1`);二次点击同样 `cache=1`;把宿主窗口关掉换新窗口 resume 后点击→旧句柄失效自动重解析,不跳错、不假死 |
| T34 | 遮挡诚实(hover 不隔窗说谎) | 右键宠物打开菜单,把光标停在菜单上、且几何位置落在卡片行内;再用任意其它窗口盖住卡片后把光标移到其上 | 两种遮挡下卡片的珊瑚环/杏白底**均不得点亮**(点击到不了卡片,亮=许诺假点击);菜单关闭、遮挡移开后 hover 立即恢复(T32 不回归)。机制=WindowFromPoint 顶层窗口核验,非纯几何判断 |
| T35 | VS Code tab 级跳转(伴生扩展,正向) | 装 `vscode-ext/claude-pet-jump`(拷入 `~\.vscode\extensions\shin620265.claude-pet-jump-0.1.0`)后 Reload Window;同一 VS Code 窗口开 ≥2 个 claude 终端 tab,手动切到**另一个** tab;点目标会话的卡片 | 窗口到前台**且**终端面板自动切到该会话的 tab;`~\.claude\pet-data\jump-ack.json` 的 nonce 与对应 `jump-req-<nonce>.json` 一致、`matchedPid`=该终端 shell(pwsh)PID;events.log 跳转行 `ok=1 req=1`;**快速连点 4 次(两行交替)全部 `req=1`**(坑 12 的 Replace $null 回归即在此翻车) |
| T36 | 伴生扩展诚实边界(负向) | ①卸掉扩展(删目录+Reload):点卡;②两个 VS Code 窗口各跑 claude:点 A 窗口会话的卡;③手写一个 `jump-req-<32位hex>.json`(ts 比当前早 60s,pids 填真实终端 shell PID);④把上一次成功的 request 文件原样重写一遍(nonce 不变) | ①窗口级照旧(=1.2.0 行为),无新 ack,不报错;②只有 A 窗口切 tab,B 窗口 terminals 纹丝不动(归属=processId 证明,不是"最顶窗口猜");③④扩展**均不得**切 tab(5s 过期 + nonce 去重,陈旧文件永不误翻) |

**T12 找宠物窗口并踩到底层的片段**
```powershell
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class WZ{
 public delegate bool EP(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int cx,int cy,uint f);
 public static IntPtr FindPet(uint pid){IntPtr r=IntPtr.Zero;EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid){int e=GetWindowLong(h,-20);if((e&0x80000)!=0){r=h;return false;}}return true;},IntPtr.Zero);return r;}
 public static bool IsTop(IntPtr h){return (GetWindowLong(h,-20)&0x8)!=0;}
 public static void Bury(IntPtr h){SetWindowPos(h,(IntPtr)(-2),0,0,0,0,0x13);SetWindowPos(h,(IntPtr)1,0,0,0,0,0x13);} }
"@
$petPid=[uint32](Get-Content "$HOME\.claude\pet-data\pet.pid" | Select -First 1)   # 别用 $pid,是只读自动变量
$h=[WZ]::FindPet($petPid); "before=$([WZ]::IsTop($h))"; [WZ]::Bury($h); "buried=$([WZ]::IsTop($h))"
Start-Sleep -Milliseconds 2600; "after2.6s=$([WZ]::IsTop($h))  # 期望 True"
```

---

## 5. 必须复核的历史坑(防回归)
1. **5.1 中文乱码**:菜单/卡片中文、`·` 分隔是否正常(T15)。源码里不得出现新的中文/符号字面量。
2. **变量名大小写撞名**:i18n 对象必须是 `$script:STR`,不得退回 `$script:T`(会被行标签 `$t` 覆盖,渲染时 fallback)。
3. **pwsh vs powershell**:`/my-pet` 输出必须是 ASCII `on/off`(中文经 `!` 捕获会乱码)。
4. **SessionStart 重复触发**:compact/resume 不得覆盖已有会话标题(T6)。
5. **置顶降级**:必须有周期性重声明(T12)。
6. **重启不重复叮**:常驻重启首轮应静音(`firstPoll`),不要把已有 done/attention 重播(T8)。
7. **空闲误报**:Notification 的 idle/auth/elicitation 必须过滤(T14)。
8. **PID 复用误杀 / 双实例**:toggle、session-start 必须先核验进程身份再 Stop/认定在跑(T19);常驻必须持命名 Mutex(T16)。
9. **删错钩子**:busy 必须挂 PostToolUse+PostToolUseFailure(批准后复位 attention 的兜底,对一切工具生效);PreToolUse 在弹窗前触发,挂它等于批准后无人复位(1.0.2 踩过,T14)。
10. **权限通知的 6 秒**: "需确认"即时性必须靠 PermissionRequest 钩子(async);Notification 有 Claude Code 内置 6s 防打扰延迟,只能当兜底(T22)。
11. **认命令翻卡不得说谎**:错误命令在跑、或匹配进程早于弹窗出生,都**不得**翻卡(T27 负向);pet-event.ps1 与 pet-resident.ps1 的归一化正则必须逐字一致,改一处必改两处。
12. **跳窗不得指鹿为马**:Jump-Row 的 claude 进程名门禁、Find-HostWindow 的祖先出生时间守卫(晚于子进程 +2s 即断链)都不得删——PID 被系统复用后点卡激活陌生窗口是最恶性的说谎(T30 负向);跳不了只准摇头,不准挑"最像的窗口"兜底。

---

## 6. 报告格式
每项一行:`T# | PASS/FAIL | 证据(命令输出摘录/截图文件名/测量值) | 失败时最小复现`。
最后给:总体结论 + 阻塞项清单 + 建议(尤其 T18 可移植性,关系到能否发布)。

---

## 7. 收尾(测完务必恢复)
- 删除所有测试会话文件:`Remove-Item "$HOME\.claude\pet-data\sessions\t_*" -Force`
- 恢复 `lang.txt`=`auto`、`sound.txt`=`on`(或删除让其回默认)
- 确认只有 1 个常驻进程且宠物处于"开"
- 删除临时调试文件(若有 `i18ndbg*.txt`、`$env:TEMP\pet-*.png`)
