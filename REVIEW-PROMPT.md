# 测试交接 Prompt —— Claude 桌面宠物(给 reviewer)

> 把本文件整篇交给 reviewer(人或另一个 Claude Code agent)。它是自包含的:照着做即可系统化验证这个应用。

---

## 0. 你的角色与目标
你是这个 **Windows 桌面常驻宠物 + Claude Code 会话提醒**应用的**测试/复核方**。目标:
1. 逐项验证功能、健壮性、是否符合既定的最佳实践;
2. 每项给出 **通过/失败 + 证据**(命令输出 / 截图 / 测量值);失败要给**最小复现**;
3. 复核"历史坑"是否回归(见 §5);
4. 全程**只测不改**;若发现 bug,报告给负责人,不要擅自改实现。

应用根目录:`~/.claude/pet`

---

## 1. 先读这两份
- `README.md` —— 用户手册(三语),理解功能与交互。
- `MAINTAINERS.md` —— 架构、文件清单、工作原理、踩过的坑。

---

## 2. 环境硬约束(测错的根源,务必先懂)
- **常驻 `pet-resident.ps1` 跑在 `powershell.exe`(5.1, STA)**;钩子脚本跑在 `pwsh`(7)。WinForms 必须 STA。
- **5.1 编码坑**:5.1 把无 BOM 的 UTF-8 当 GBK 读 → 常驻源码**不能有中文/符号字面量**。所有中文来自 `strings.json` / `sessions` 文件(UTF-8 读)或 `[char]0xXXXX`。看到卡片/菜单乱码 = 这条破了。
- **DPI**:常驻是 Per-Monitor DPI 感知。**你的截图进程也必须设 DPI 感知**,否则坐标对不上(见 §3 片段)。
- **单实例**:`pet.pid` 记录当前常驻 PID。测试时务必确认只有 1 个常驻进程,避免"两个常驻叠加"误导(历史上踩过)。
- **沙箱**:`cmd /c` 可能被拦;给子进程喂 stdin 用管道或 `Start-Process -RedirectStandardInput`。
- **会话状态文件格式**(`sessions\<id>`,单行,TAB 分隔):
  `key <TAB> label <TAB> title <TAB> detail <TAB> epochMillis`
  - `key` ∈ `thinking|attention|done|idle`(决定颜色/图标/本地化文案);`label` 已被常驻忽略(按 key 本地化),填占位即可;`title`=卡片标题;`detail`=状态行后半句。

---

## 3. 可复用片段(直接抄)

**重启常驻**
```powershell
$d="$HOME\.claude\pet"
Get-Content "$d\pet.pid" | % { Stop-Process -Id $_ -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 600
$p=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$d\pet-resident.ps1"
$p.Id | Set-Content "$d\pet.pid"; Start-Sleep -Seconds 3
"alive=$(-not $p.HasExited)"
```

**注入一个会话状态(模拟某会话进入某状态)**
```powershell
$sd="$HOME\.claude\pet\sessions"; $e=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
[IO.File]::WriteAllText("$sd\t_attn", ("attention`tX`t测试标题`t最近一句输入`t$e"), (New-Object Text.UTF8Encoding($false)))
# 用完删:Remove-Item "$sd\t_*" -Force
```

**触发一个真实钩子(带 stdin JSON,UTF-8)**
```powershell
$d="$HOME\.claude\pet"
'{"session_id":"t_hook","cwd":"D:\\path\\myproject","prompt":"做一个功能"}' | pwsh -NoProfile -ExecutionPolicy Bypass -File "$d\pet-event.ps1" prompt
# 其它事件:done / busy / attention(需 message/type)/ idle / end
# SessionStart:把 source 设 compact/clear/startup 测标题保留/重置
'{"session_id":"t_hook","cwd":"D:\\path\\myproject","source":"compact"}' | pwsh -NoProfile -File "$d\pet-session-start.ps1"
```

**DPI 感知截图(卡片区域)**
```powershell
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class D{ [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);}
"@
[D]::SetProcessDpiAwarenessContext([IntPtr](-4))|Out-Null
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$d="$HOME\.claude\pet"; $pos=(Get-Content "$d\pet-pos.txt") -split ','; $px=[int]$pos[0]; $py=[int]$pos[1]
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
MW "$HOME\.claude\pet\done.wav"; MW "$HOME\.claude\pet\attn.wav"
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
| T14 | 钩子映射 | 逐个触发 prompt/busy/done/attention/idle/end | 状态正确流转;`waiting for`/idle_prompt/auth_success/elicitation_* 被过滤不弹 |
| T15 | 编码 | 看菜单「关闭宠物」「·」分隔、中文卡片 | 无乱码(无「路」等) |
| T16 | 单实例 | 多次 SessionStart / toggle | 始终只有 1 个 `pet-resident.ps1` 进程 |
| T17 | 多界面并存 | 在 WT/VS Code 终端/PowerShell 同时开 Claude | 各自一张卡;任一 claude.exe 在即不退 |
| T18 | (发布前)可移植性 | 全仓搜 `C:\Users\` 一类写死绝对路径 | 报告所有写死的绝对路径(应为 `$PSScriptRoot`/`$env:USERPROFILE`) |

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
$pid=[uint32](Get-Content "$HOME\.claude\pet\pet.pid" | Select -First 1)
$h=[WZ]::FindPet($pid); "before=$([WZ]::IsTop($h))"; [WZ]::Bury($h); "buried=$([WZ]::IsTop($h))"
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

---

## 6. 报告格式
每项一行:`T# | PASS/FAIL | 证据(命令输出摘录/截图文件名/测量值) | 失败时最小复现`。
最后给:总体结论 + 阻塞项清单 + 建议(尤其 T18 可移植性,关系到能否发布)。

---

## 7. 收尾(测完务必恢复)
- 删除所有测试会话文件:`Remove-Item "$HOME\.claude\pet\sessions\t_*" -Force`
- 恢复 `lang.txt`=`auto`、`sound.txt`=`on`(或删除让其回默认)
- 确认只有 1 个常驻进程且宠物处于"开"
- 删除临时调试文件(若有 `i18ndbg*.txt`、`$env:TEMP\pet-*.png`)
