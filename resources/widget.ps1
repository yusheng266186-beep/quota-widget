# 额度挂件 —— 桌面右上角的 Command Code + ChatGPT 额度浮窗
# 由 start.vbs 静默拉起；数据由 fetch-quota.mjs 提供。

[CmdletBinding()]
param(
    [switch]$Console   # 调试用：保留控制台输出
)

$ErrorActionPreference = 'Stop'

# 单实例：重复启动时静默退出，避免桌面上出现两个挂件
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'QuotaWidget.SingleInstance')
if (-not $script:InstanceMutex.WaitOne(0)) { exit }

# 兜底：任何未捕获异常都记进 widget.log，而不是让挂件静默消失
trap {
    Write-Log "未捕获异常: $($_.Exception.Message) @ 行 $($_.InvocationInfo.ScriptLineNumber)"
    continue
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$Root        = $PSScriptRoot
$ConfigPath  = Join-Path $Root 'config.json'
$FetchScript = Join-Path $Root 'fetch-quota.mjs'
$CacheFile   = Join-Path $Root 'quota-cache.json'
$LogFile     = Join-Path $Root 'widget.log'

# ------------------------------------------------------------------ 小工具

function Write-Log([string]$Message) {
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        # 用不带 BOM 的 UTF-8 追加，日志用记事本打开也不会看到多余的字符
        [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-Config {
    $defaults = [ordered]@{
        refreshSeconds   = 60
        theme            = 'dark'
        opacity          = 0.94
        margin           = 16
        topmost          = $true
        position         = $null
        proxy            = 'auto'
        nodePath         = $null
        # 自动收起（贴右上角，鼠标移过去才展开）
        autoHide         = $true
        tabWidth         = 112
        tabHeight        = 12
        hotZonePadX      = 30
        hotZonePadY      = 14
        collapseDelayMs  = 650
        expandAnimMs     = 200
        collapseAnimMs   = 160
        dockLeft         = $null
    }
    $cfg = Read-Json $ConfigPath
    $out = [ordered]@{}
    foreach ($k in $defaults.Keys) {
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains $k) -and $null -ne $cfg.$k) { $out[$k] = $cfg.$k }
        else { $out[$k] = $defaults[$k] }
    }
    return $out
}

function Save-Config($Config) {
    try {
        $merged = [ordered]@{}
        $existing = Read-Json $ConfigPath
        if ($existing) { foreach ($p in $existing.PSObject.Properties) { $merged[$p.Name] = $p.Value } }
        foreach ($k in $Config.Keys) { $merged[$k] = $Config[$k] }
        # 不写 BOM：node 侧要直接 JSON.parse 这个文件
        $json = $merged | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "保存配置失败: $($_.Exception.Message)" }
}

function Resolve-NodePath($Config) {
    if ($Config.nodePath -and (Test-Path -LiteralPath $Config.nodePath)) { return $Config.nodePath }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            "$env:ProgramFiles\nodejs\node.exe",
            "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
            "$env:APPDATA\npm\node.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    # 最后兜底：扫描用户目录下 nodejs 发行包
    $hit = Get-ChildItem -Path (Join-Path $env:USERPROFILE 'nodejs') -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Esc([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Format-Clock([double]$EpochMs) {
    if (-not $EpochMs -or $EpochMs -le 0) { return '' }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$EpochMs).ToLocalTime().ToString('MM-dd HH:mm')
}

function Get-ResetSuffix([double]$EpochMs) {
    $clock = Format-Clock $EpochMs
    if ([string]::IsNullOrEmpty($clock)) { return '' }
    return ' · {0} 重置' -f $clock
}

function Format-Reset([double]$EpochMs) {
    if (-not $EpochMs -or $EpochMs -le 0) { return '' }
    # 注意：[int] 在 PowerShell 里是四舍五入，时间换算必须用 Floor
    $sec = [long][math]::Floor(($EpochMs - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000)
    if ($sec -le 60) { return '即将重置' }
    if ($sec -lt 3600) { return '{0}m' -f [long][math]::Floor($sec / 60) }
    if ($sec -lt 86400) {
        return '{0}h{1:00}m' -f [long][math]::Floor($sec / 3600), [long][math]::Floor(($sec % 3600) / 60)
    }
    return '{0}d{1:00}h' -f [long][math]::Floor($sec / 86400), [long][math]::Floor(($sec % 86400) / 3600)
}

# ------------------------------------------------------------------ 配置 / 调色板

$Config    = Get-Config
$NodePath  = Resolve-NodePath $Config
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '额度挂件.lnk'

# 开机自启快捷方式该指向谁：优先 EXE（双击无黑框，且和挂件用的同一份文件），
# 其次同目录的 EXE，最后退回 wscript + start.vbs。
function Get-LaunchTarget {
    $fromExe = $env:QUOTA_WIDGET_LAUNCHER
    if ($fromExe -and (Test-Path -LiteralPath $fromExe)) {
        return @{ Path = $fromExe; Args = '' }
    }
    $exe = Join-Path $Root 'QuotaWidget.exe'
    if (Test-Path -LiteralPath $exe) {
        return @{ Path = $exe; Args = '' }
    }
    return @{ Path = (Join-Path $env:SystemRoot 'System32\wscript.exe'); Args = ('"{0}"' -f (Join-Path $Root 'start.vbs')) }
}

$script:Palettes = @{
    dark = @{
        card    = '#F20E1117'
        border  = '#24FFFFFF'
        sep     = '#14FFFFFF'
        primary = '#E8EBF2'
        muted   = '#7E869B'
        title   = '#C3C9D8'
        accent  = '#7C9CFF'
        track   = '#1AFFFFFF'
        ok      = '#3ED598'
        warn    = '#F5C05E'
        danger  = '#FF6B7A'
        hover   = '#18FFFFFF'
        tab     = '#E61A2029'
    }
    light = @{
        card    = '#F7FFFFFF'
        border  = '#22000000'
        sep     = '#14000000'
        primary = '#1B1F2A'
        muted   = '#6B7280'
        title   = '#3A4152'
        accent  = '#3D5AFE'
        track   = '#14000000'
        ok      = '#16A34A'
        warn    = '#D97706'
        danger  = '#DC2626'
        hover   = '#10000000'
        tab     = '#E6E9EDF3'
    }
}
$P = $script:Palettes[$Config.theme]
if (-not $P) { $P = $script:Palettes.dark }

# ------------------------------------------------------------------ 窗口外壳

# 结构：rootGrid 下挂两个兄弟节点 —— panelClip(裁剪，让出手柄高度，内含 card) 和 tab(收起手柄)。
# 手柄必须是 rootGrid 的直接子节点，放进 panelClip 会被它的上边距顶下去、离屏幕顶边出现缝隙。
# 展开/收起只动画 card 上的 TranslateTransform.Y，窗口尺寸自始至终不变。
# 这么做是为了帧率：改窗口高度每帧都会触发一次真实的 SetWindowPos（分层窗口尤其贵），
# 而改 RenderTransform 是合成层的事，走 WPF 动画时钟，能稳稳跑在刷新率上。
# 收起后窗口虽然还在，但下半部分是完全透明的 —— 实测分层窗口的透明像素会被命中测试
# 放过，点击直接穿透到下面的窗口，不会留隐形挡板。
$script:TabH = [double]$Config.tabHeight
$script:TabW = [double]$Config.tabWidth

$shellXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="额度挂件" Width="278" SizeToContent="Manual" Height="300"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" Topmost="$($Config.topmost.ToString().ToLower())"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        FontFamily="Microsoft YaHei UI, Segoe UI">
  <Grid x:Name="rootGrid" ClipToBounds="True" Background="Transparent">
   <Grid x:Name="panelClip" ClipToBounds="True" Margin="0,$($script:TabH),0,0">
    <Border x:Name="card" CornerRadius="14" BorderThickness="1"
            VerticalAlignment="Top"
            Background="$($P.card)" BorderBrush="$($P.border)" Padding="13,10,13,10">
      <Border.RenderTransform>
        <TranslateTransform x:Name="cardShift" Y="0"/>
      </Border.RenderTransform>
      <StackPanel>
        <Grid Margin="0,0,0,8">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Ellipse x:Name="statusDot" Width="6" Height="6" Fill="$($P.muted)" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Text="额度" FontSize="11.5" FontWeight="SemiBold" Foreground="$($P.primary)" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Border x:Name="refreshBtn" Tag="noDrag" Background="Transparent" CornerRadius="5" Padding="5,1" Cursor="Hand"
                    ToolTip="立即刷新（每 $($Config.refreshSeconds) 秒自动刷新）">
              <TextBlock x:Name="refreshGlyph" Text="&#x21BB;" FontSize="13" Foreground="$($P.muted)" VerticalAlignment="Center"/>
            </Border>
            <Border x:Name="closeBtn" Tag="noDrag" Background="Transparent" CornerRadius="5" Padding="5,1" Margin="1,0,0,0" Cursor="Hand"
                    ToolTip="退出挂件">
              <TextBlock Text="&#x00D7;" FontSize="14" Foreground="$($P.muted)" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>
      </Grid>
      <ContentControl x:Name="body"/>
      <Grid Margin="0,8,0,0">
        <TextBlock x:Name="footerLeft" FontSize="9.5" Foreground="$($P.muted)" HorizontalAlignment="Left"/>
        <TextBlock x:Name="footerRight" FontSize="9.5" Foreground="$($P.muted)" HorizontalAlignment="Right"/>
      </Grid>
    </StackPanel>
    </Border>
   </Grid>
   <Border x:Name="tab" Tag="noDrag" VerticalAlignment="Top" HorizontalAlignment="Center"
           Width="$($script:TabW)" Height="$($script:TabH)"
           CornerRadius="0,0,7,7" Background="$($P.tab)" BorderBrush="$($P.border)" BorderThickness="0,0,1,1"
           Cursor="SizeWE" ToolTip="按住可以左右拖动；鼠标移过来展开面板">
     <Ellipse x:Name="tabDot" Width="5" Height="5" Fill="$($P.muted)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
   </Border>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$shellXaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$rootGrid     = $window.FindName('rootGrid')
$panelClip    = $window.FindName('panelClip')
$card         = $window.FindName('card')
$cardShift    = $window.FindName('cardShift')
$tab          = $window.FindName('tab')
$tabDot       = $window.FindName('tabDot')
$statusDot    = $window.FindName('statusDot')
$refreshBtn   = $window.FindName('refreshBtn')
$refreshGlyph = $window.FindName('refreshGlyph')
$closeBtn     = $window.FindName('closeBtn')
$body         = $window.FindName('body')
$footerLeft   = $window.FindName('footerLeft')
$footerRight  = $window.FindName('footerRight')

$script:Spin = New-Object System.Windows.Media.RotateTransform
$refreshGlyph.RenderTransform = $script:Spin
$refreshGlyph.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

# 动画全部交给 WPF 的动画时钟（合成线程驱动），不再用 DispatcherTimer 一帧帧手推。
# 手推的问题是：PowerShell 每次 tick 都有脚本引擎开销，且节拍不保证，看着就是掉帧。
$script:EaseExpand = New-Object System.Windows.Media.Animation.CubicEase
$script:EaseExpand.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
$script:EaseCollapse = New-Object System.Windows.Media.Animation.CubicEase
$script:EaseCollapse.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn

$script:YProp = [System.Windows.Media.TranslateTransform]::YProperty
$script:AngleProp = [System.Windows.Media.RotateTransform]::AngleProperty
$script:SpinSeconds = 0.9    # 转一圈的秒数

# 把一个 DoubleAnimation 打到某个依赖属性上；From 省略时从当前值起步
function Start-Anim($Target, $Property, [double]$To, [double]$Ms, $Ease) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds([math]::Max(1, $Ms))
    if ($Ease) { $anim.EasingFunction = $Ease }
    $anim.To = $To
    $anim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $Target.BeginAnimation($Property, $anim)
}

# ------------------------------------------------------------------ 渲染

# 进度条几何：列宽 BarColW，轨道与右侧百分比之间留 BarGap。
# 轨道实际能画的宽度是 BarColW - BarGap —— 填充必须按这个宽度算，
# 否则长条会溢出轨道被裁掉，末端圆角正好落在裁切线外，看起来就是直角。
$script:BarColW = 94
$script:BarGap = 8
$script:BarTrackW = $script:BarColW - $script:BarGap
# 注意别写成 '<a>' + '<b {0}/>' + '<c>' -f $x：PowerShell 里 -f 的优先级高于 +，
# 那样只格式化最后一段，{0} 会原样留在 XAML 里爆掉。用 here-string 插值最稳。
$script:BarCols = @"
<Grid.ColumnDefinitions>
  <ColumnDefinition Width="48"/><ColumnDefinition Width="$($script:BarColW)"/><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/>
</Grid.ColumnDefinitions>
"@

# 挂件呈现的是“剩余额度”，所以颜色按剩余量判断：剩得少才报警
function Get-BarColor([double]$RemainingPct) {
    if ($RemainingPct -lt 15) { return $P.danger }
    if ($RemainingPct -lt 40) { return $P.warn }
    return $P.ok
}

function New-BarRow([string]$Label, $Window, [string]$Tip) {
    # $Window: @{ remainingPct; resetAt } 或 $null（此时 $Tip 就是那一行的说明文字）
    $labelText = Esc $Label
    if ($null -eq $Window) {
        return @"
<Grid Height="17">
  $($script:BarCols)
  <TextBlock Grid.Column="0" Text="$labelText" FontSize="10" Foreground="$($P.muted)" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="1" Grid.ColumnSpan="3" Text="$(Esc $Tip)" FontSize="9.5" Foreground="$($P.muted)" VerticalAlignment="Center"/>
</Grid>
"@
    }
    $left  = [double]$Window.remainingPct
    $color = Get-BarColor $left
    $barW  = [math]::Round($script:BarTrackW * [math]::Min(100, [math]::Max(0, $left)) / 100, 1)
    $fill  = ''
    if ($left -gt 0) {
        # 还剩一点点也要看得见，别让 1% 看着像 0%
        if ($barW -lt 3) { $barW = 3 }
        $fill = '<Border Background="{0}" CornerRadius="2.5" HorizontalAlignment="Left" Width="{1}"/>' -f $color, $barW
    }
    $resetText = Format-Reset ([double]$Window.resetAt)
    if ([string]::IsNullOrEmpty($resetText)) { $resetText = '—' }

    $tipAttr = ''
    if (-not [string]::IsNullOrEmpty($Tip)) { $tipAttr = ' ToolTip="{0}"' -f (Esc $Tip) }

    return @"
<Grid Height="17"$tipAttr>
  $($script:BarCols)
  <TextBlock Grid.Column="0" Text="$labelText" FontSize="10" Foreground="$($P.muted)" VerticalAlignment="Center"/>
  <Grid Grid.Column="1" Height="5" VerticalAlignment="Center" Margin="0,0,$($script:BarGap),0">
    <Border Background="$($P.track)" CornerRadius="2.5"/>
    $fill
  </Grid>
  <TextBlock Grid.Column="2" Text="$([math]::Round($left))%" FontSize="10" Foreground="$color" HorizontalAlignment="Right" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="3" Text="$(Esc $resetText)" FontSize="9.5" Foreground="$($P.muted)" HorizontalAlignment="Right" VerticalAlignment="Center"/>
</Grid>
"@
}

function New-Section([string]$Title, [string]$Right, [string]$TitleColor, [string[]]$Rows, [string]$RightColor) {
    if ([string]::IsNullOrEmpty($RightColor)) { $RightColor = $P.muted }
    $rowsXml = ($Rows -join "`n")
    return @"
<StackPanel Margin="0,0,0,9">
  <Grid Margin="0,0,0,3">
    <TextBlock Text="$(Esc $Title)" FontSize="9.5" FontWeight="SemiBold" Foreground="$TitleColor"
               VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    <TextBlock Text="$(Esc $Right)" FontSize="9.5" Foreground="$RightColor" HorizontalAlignment="Right" VerticalAlignment="Center"/>
  </Grid>
  $rowsXml
</StackPanel>
"@
}

function New-Separator {
    return '<Border Height="1" Background="' + $P.sep + '" Margin="0,-3,0,7"/>'
}

function Render($Data) {
    if (-not $Data) { return }
    try {
        Render-Inner $Data
    } catch {
        # 渲染链路任何异常都不该把挂件整个带走
        Write-Log "渲染异常: $($_.Exception.Message) @ 行 $($_.InvocationInfo.ScriptLineNumber)"
        $script:FooterLeftOverride = '渲染出错'
        Set-Status 'error'
    }
}

function Render-Inner($Data) {
    $parts = @()

    # 列图例：说清楚这两列分别是“剩余”和“重置倒计时”，因为进度条画的是剩余量
    $parts += @"
<Grid Margin="0,0,0,5">
  $($script:BarCols)
  <TextBlock Grid.Column="2" Text="剩余" FontSize="8.5" Foreground="$($P.muted)" HorizontalAlignment="Right" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="3" Text="重置倒计时" FontSize="8.5" Foreground="$($P.muted)" HorizontalAlignment="Right" VerticalAlignment="Center"/>
</Grid>
"@

    # ---- Command Code ----
    $cc = $Data.commandCode
    if ($cc) {
        if ($cc.ok) {
            $right = '{0} · 剩余 {1:0.##}' -f $cc.plan, $cc.remainingCredits

            # 月度额度：按套餐总额度算剩余比例，拿不到总额度就退化成纯文字
            $monthWindow = $null
            $monthTip = ''
            if ($cc.totalCredits -and $null -ne $cc.remainingPct) {
                $monthWindow = @{ remainingPct = [double]$cc.remainingPct; resetAt = $cc.periodEnd }
                $monthTip = '本月剩余 {0:0.##} / {1:0.##} 积分{2}' -f $cc.remainingCredits, $cc.totalCredits, (Get-ResetSuffix $cc.periodEnd)
            } else {
                $monthTip = '本月剩余 {0:0.##} 积分（这个套餐的月度总额度未知）' -f $cc.remainingCredits
            }

            $rows = @(
                (New-BarRow '本月'   $monthWindow $monthTip),
                (New-BarRow '5 小时' $cc.fiveHour ('剩余 {0:0.##} / {1:0.##} 积分{2}' -f $cc.fiveHour.remaining, $cc.fiveHour.cap, (Get-ResetSuffix $cc.fiveHour.resetAt))),
                (New-BarRow '本周'   $cc.weekly   ('剩余 {0:0.##} / {1:0.##} 积分{2}' -f $cc.weekly.remaining, $cc.weekly.cap, (Get-ResetSuffix $cc.weekly.resetAt)))
            )
            $parts += New-Section 'Command Code' $right $P.accent $rows
        } else {
            $rows = @('<TextBlock Text="' + (Esc ("取数失败：" + $cc.error)) + '" FontSize="9.5" Foreground="' + $P.danger + '" TextWrapping="Wrap"/>')
            $parts += New-Section 'Command Code' '' $P.accent $rows
        }
    }

    # ---- ChatGPT 账号 ----
    $cg = $Data.chatgpt
    if ($cg -and $cg.accounts -and $cg.accounts.Count -gt 0) {
        $parts += New-Separator
        foreach ($acc in $cg.accounts) {
            $badge = ''
            $badgeColor = $P.muted
            if ($acc.plan) { $badge = $acc.plan.ToString().ToUpper() }
            if ($acc.current) { $badge = "$badge · 当前" }
            if (-not $acc.ok) {
                $rows = @('<TextBlock Text="' + (Esc ("取数失败：" + $acc.error)) + '" FontSize="9.5" Foreground="' + $P.danger + '" TextWrapping="Wrap"/>')
            } else {
                if ($acc.limited) { $badge = "$badge · 已用尽"; $badgeColor = $P.danger }
                elseif ($acc.source -eq 'cache') { $badge = "$badge · 缓存" }
                $rows = @(
                    (New-BarRow '5 小时' $acc.fiveHour ('剩余 {0}%{1}' -f [math]::Round([double]$acc.fiveHour.remainingPct), (Get-ResetSuffix $acc.fiveHour.resetAt))),
                    (New-BarRow '本周'   $acc.weekly   ('剩余 {0}%{1}' -f [math]::Round([double]$acc.weekly.remainingPct), (Get-ResetSuffix $acc.weekly.resetAt)))
                )
            }
            $parts += New-Section $acc.email $badge $P.title $rows $badgeColor
        }
    } elseif ($cg) {
        $rows = @('<TextBlock Text="' + (Esc ("取数失败：" + $cg.error)) + '" FontSize="9.5" Foreground="' + $P.danger + '" TextWrapping="Wrap"/>')
        $parts += New-Separator
        $parts += New-Section 'ChatGPT' '' $P.title $rows
    }

    $bodyXml = '<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TextElement.FontFamily="Microsoft YaHei UI, Segoe UI">' + ($parts -join "`n") + '</StackPanel>'

    try {
        $body.Content = [Windows.Markup.XamlReader]::Parse($bodyXml)
    } catch {
        Write-Log "渲染失败: $($_.Exception.Message)"
        $body.Content = New-Object System.Windows.Controls.TextBlock
    }

    # 页脚交给轮询定时器持续刷新（倒计时 / 正在刷新），这里只记录状态
    $script:LastUpdate = Get-Date
    $script:FooterLeftOverride = $null
    $script:ProxyLabel = if ($Data.proxy) { '代理' } else { '直连' }

    # 内容高度可能变了（错误提示、段落增减），同步一次窗口高度与收起位移
    if ($script:AutoHideOn -and $script:Positioned) { Sync-FullHeight | Out-Null }
}

function Set-Status([string]$State) {
    $color = switch ($State) {
        'ok'      { $P.ok }
        'error'   { $P.danger }
        'loading' { $P.warn }
        default   { $P.muted }
    }
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $statusDot.Fill = $brush
    # 收起状态下只剩这块小手柄，状态点就是唯一能一眼看到的信息
    $tabDot.Fill = $brush

    if ($State -eq 'loading') { Start-Spin } else { Stop-Spin }
}

# 刷新图标：用 WPF 动画连续转，而不是按 tick 加角度（那样一秒才几步，必然卡）。
function Start-Spin {
    if ($script:Spinning) { return }
    $script:Spinning = $true
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = 360
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromSeconds($script:SpinSeconds)
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $script:Spin.BeginAnimation($script:AngleProp, $anim)
}

# 停的时候别硬切：按同样角速度把当前这一圈转完。
# 不需要 Completed 回调 —— 把基值归零，动画停在本圈的整数倍上，
# 360 的整数倍和 0 视觉上完全一样，停下时不会有跳变。
function Stop-Spin {
    if (-not $script:Spinning) { return }
    $script:Spinning = $false
$script:DbgLastY = 0.0
    $cur = [double]$script:Spin.Angle
    $script:Spin.BeginAnimation($script:AngleProp, $null)
    $script:Spin.Angle = 0
    if ($cur -lt 5) { return }          # 几乎没转起来，直接归位
    $target = 360 * [math]::Ceiling(($cur + 2) / 360)
    $ms = ($target - $cur) / 360 * $script:SpinSeconds * 1000
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = $cur
    $anim.To = $target
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds([math]::Max(60, $ms))
    $script:Spin.BeginAnimation($script:AngleProp, $anim)
}

# ------------------------------------------------------------------ 取数

$script:Fetching = $false
$script:FetchProc = $null
$script:FetchStart = $null
$script:Spinning = $false
$script:LastData = $null
$script:LastUpdate = $null
$script:NextFetchAt = $null
$script:ProxyLabel = ''
$script:FooterLeftOverride = $null
$script:RefreshSeconds = [math]::Max(15, [int]$Config.refreshSeconds)
$script:RefreshTimer = $null

# 每次开始取数都重置倒计时（手动点刷新也会把下一轮自动刷新往后推）
function Reset-RefreshSchedule {
    $script:NextFetchAt = (Get-Date).AddSeconds($script:RefreshSeconds)
    if ($script:RefreshTimer) {
        $script:RefreshTimer.Stop()
        $script:RefreshTimer.Start()
    }
}

function Start-Fetch {
    if ($script:Fetching) { return }
    if (-not $NodePath) {
        Set-Status 'error'
        $body.Content = [Windows.Markup.XamlReader]::Parse('<TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Text="没找到 node.exe，请安装 Node.js 或在 config.json 里指定 nodePath" FontSize="10" Foreground="#FF6B7A" TextWrapping="Wrap"/>')
        $script:FooterLeftOverride = '没找到 node.exe'
        return
    }

    $script:Fetching = $true
    $script:FetchStart = Get-Date
    Set-Status 'loading'
    Remove-Item -LiteralPath $CacheFile -ErrorAction SilentlyContinue

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $NodePath
        $psi.Arguments = '"{0}" --out "{1}"' -f $FetchScript, $CacheFile
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $script:FetchProc = [System.Diagnostics.Process]::Start($psi)
        Reset-RefreshSchedule
    } catch {
        Write-Log "启动取数进程失败: $($_.Exception.Message)"
        $script:Fetching = $false
        $script:FooterLeftOverride = '启动取数失败'
        Set-Status 'error'
    }
}

function Complete-Fetch {
    $script:Fetching = $false
    $exitCode = $null
    $errText = ''
    $proc = $script:FetchProc
    if ($proc) {
        try {
            $exitCode = $proc.ExitCode
            $errText = $proc.StandardError.ReadToEnd()
        } catch { }
        try { $proc.Dispose() } catch { }
    }

    $data = Read-Json $CacheFile
    if ($data) {
        $script:LastData = $data
        Render $data
        $ok = ($data.commandCode -and $data.commandCode.ok) -or ($data.chatgpt -and $data.chatgpt.ok)
        Set-Status ($(if ($ok) { 'ok' } else { 'error' }))
        if (-not $ok) {
            Write-Log "取数未成功: $($data.commandCode.error) | $($data.chatgpt.error)"
            $script:FooterLeftOverride = '取数未成功'
        }
        if ($errText) { Write-Log "取数 stderr: $errText" }
    } else {
        Set-Status 'error'
        $script:FooterLeftOverride = '更新失败'
        # 一定要记：否则一次静默失败在日志里查不到任何痕迹
        $detail = if ($errText) { " stderr: $errText" } else { '（没有任何 stderr 输出）' }
        Write-Log ("取数失败：没有拿到 quota-cache.json，node 退出码=$exitCode$detail")
    }
    $script:FetchProc = $null
}

# ------------------------------------------------------------------ 控制器

# 页脚每秒刷新一次，显示“正在刷新 / 上次更新时刻 + 下次刷新倒计时”
function Update-Footer {
    if ($script:Fetching) {
        $left = '正在刷新…'
    } elseif ($script:FooterLeftOverride) {
        $left = $script:FooterLeftOverride
    } elseif ($script:LastUpdate) {
        $left = '更新 ' + $script:LastUpdate.ToString('HH:mm:ss')
    } else {
        $left = '启动中…'
    }

    $right = @()
    if ($script:ProxyLabel) { $right += $script:ProxyLabel }
    if ($script:NextFetchAt) {
        $sec = [long][math]::Ceiling(($script:NextFetchAt - (Get-Date)).TotalSeconds)
        if ($sec -lt 0) { $sec = 0 }
        $right += '{0}s 后刷新' -f $sec
    } else {
        $right += '每 {0}s 自动刷新' -f $script:RefreshSeconds
    }
    $rightText = ($right -join ' · ')

    # 只在文本真的变了才赋值：这个函数每 120ms 跑一次，无脑写会白白触发文本布局
    if ($footerLeft.Text -ne $left) { $footerLeft.Text = $left }
    if ($footerRight.Text -ne $rightText) { $footerRight.Text = $rightText }
}

# --------------------------------------------------- 自动收起（贴边悬浮）

$script:Collapsed = $false
$script:FullH = 0.0
$script:CardH = 0.0
$script:LeaveSince = $null
$script:AutoHideOn = [bool]$Config.autoHide

# 面板自然高度（不含手柄）。对根 Grid 做一次无限高度测量，不动 SizeToContent，
# 否则收起状态下窗口会先弹到全高再量，看着闪一下。
function Measure-FullHeight {
    $rootGrid.InvalidateMeasure()
    $rootGrid.Measure((New-Object System.Windows.Size($window.Width, [double]::PositiveInfinity)))
    $h = [double]$rootGrid.DesiredSize.Height
    $rootGrid.InvalidateMeasure()
    if ($h -lt $script:TabH) { $h = $script:TabH }
    return $h
}

function Sync-FullHeight {
    $h = Measure-FullHeight
    if ([math]::Abs($h - $script:FullH) -lt 0.5) { return $false }
    $script:FullH = $h
    $script:CardH = [math]::Max(1, $h - $script:TabH)
    if ($script:AutoHideOn) {
        $window.Height = $h
        if ($script:Collapsed) { $cardShift.Y = -$script:CardH }   # 收起态要跟着新高度对齐
    }
    return $true
}

# 位置：自动收起时必须贴在屏幕顶边，否则“从顶上滑下来”的观感就没了
function Set-DockedPosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = if ($null -ne $Config.dockLeft) { [double]$Config.dockLeft }
    else { $wa.Right - $window.Width - [double]$Config.margin }
    $window.Left = [math]::Min([math]::Max($left, $wa.Left), $wa.Right - $window.Width)
    $window.Top = $wa.Top
}

$script:ExpandMs = [double][math]::Max(60, [int]$Config.expandAnimMs)
$script:CollapseMs = [double][math]::Max(60, [int]$Config.collapseAnimMs)

function Expand-Panel {
    if (-not $script:Collapsed) { return }
    $script:Collapsed = $false
    Sync-FullHeight | Out-Null
    Start-Anim $cardShift $script:YProp 0 $script:ExpandMs $script:EaseExpand
}

function Collapse-Panel {
    if ($script:Collapsed) { return }
    $script:Collapsed = $true
    Start-Anim $cardShift $script:YProp (-$script:CardH) $script:CollapseMs $script:EaseCollapse
}

# 光标位置：Cursor.Position 是物理像素，WPF 的 Left/Top 是 DIP，按 DPI 缩放换算
function Get-CursorDip {
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $cur = [System.Windows.Forms.Cursor]::Position
    return @{ X = $cur.X / $dpi.DpiScaleX; Y = $cur.Y / $dpi.DpiScaleY }
}

$script:PointerInside = $false
$script:Dragging = $false
$script:DragStartCursorX = 0.0
$script:DragStartLeft = 0.0

function Update-AutoHide {
    if (-not $script:AutoHideOn) { return }
    try { Update-AutoHideInner } catch {
        Write-Log "自动收起逻辑异常: $($_.Exception.Message) @ 行 $($_.InvocationInfo.ScriptLineNumber)"
    }
}

function Update-AutoHideInner {
    if ($script:Dragging) { return }   # 拖动过程中不要收起，否则手感很怪
    # 右键菜单弹出时鼠标必然在窗口外，这时候收起会把菜单连带弄没
    if ($script:Menu -and $script:Menu.IsOpen) { $script:PointerInside = $true; $script:LeaveSince = $null; return }

    $c = Get-CursorDip

    # 注意：窗口现在是固定全高的（面板靠位移藏起来），所以不能用 window.Height 判断“在不在挂件里”，
    # 那会把整块 278x308 的区域都算进去，鼠标在下面几百像素也会触发。要按“看得见的范围”算：
    #   收起时 = 手柄本身；展开时 = 面板卡片
    $tabW = [double]$Config.tabWidth
    $tabL = $window.Left + ($window.Width - $tabW) / 2
    $tabT = $window.Top
    $padX = [double]$Config.hotZonePadX
    $padY = [double]$Config.hotZonePadY
    # 热区：就是手柄四周一点点，不做“整个右上角都是热区”
    $inHotZone = ($c.X -ge ($tabL - $padX)) -and ($c.X -le ($tabL + $tabW + $padX)) -and
    ($c.Y -ge ($tabT - $padY)) -and ($c.Y -le ($tabT + $script:TabH + $padY))

    $inPanel = $false
    if (-not $script:Collapsed) {
        $inPanel = ($c.X -ge $window.Left) -and ($c.X -le ($window.Left + $window.Width)) -and
        ($c.Y -ge ($window.Top + $script:TabH)) -and ($c.Y -le ($window.Top + $script:FullH))
    }

    $script:PointerInside = $inHotZone -or $inPanel

    if ($script:PointerInside) {
        $script:LeaveSince = $null
        Expand-Panel
        return
    }
    if ($script:Collapsed) { return }
    if (-not $script:LeaveSince) { $script:LeaveSince = Get-Date }
    if (((Get-Date) - $script:LeaveSince).TotalMilliseconds -ge [double]$Config.collapseDelayMs) {
        $script:LeaveSince = $null
        Collapse-Panel
    }
}

# 切换自动收起（菜单里可以随时切）
function Apply-AutoHideMode {
    if ($script:AutoHideOn) {
        $tab.Visibility = 'Visible'
        $card.Margin = New-Object System.Windows.Thickness(0, $script:TabH, 0, 0)
        Set-DockedPosition
        # 窗口保持全高不动，展开/收起只挪面板
        $window.SizeToContent = 'Manual'
        Sync-FullHeight | Out-Null
        $window.Height = $script:FullH
        $panelClip.Margin = New-Object System.Windows.Thickness(0, $script:TabH, 0, 0)
        $cardShift.BeginAnimation($script:YProp, $null)
        $cardShift.Y = 0
        $script:Collapsed = $false          # 先摆在展开态，再由 Update-AutoHide 按鼠标位置决定
        $script:LeaveSince = Get-Date
    } else {
        $tab.Visibility = 'Collapsed'
        $panelClip.Margin = New-Object System.Windows.Thickness(0)
        $cardShift.BeginAnimation($script:YProp, $null)
        $cardShift.Y = 0
        $script:Collapsed = $false
        $window.SizeToContent = 'Height'
        $pos = $Config.position
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($pos -and $null -ne $pos.left -and $null -ne $pos.top) {
            $window.Left = [double]$pos.left
            $window.Top = [double]$pos.top
        }
        $window.Left = [math]::Min([math]::Max($window.Left, $wa.Left), $wa.Right - $window.Width)
        $window.Top = [math]::Min([math]::Max($window.Top, $wa.Top), $wa.Bottom - 60)
    }
}

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$pollTimer.Add_Tick({
        if ($script:Fetching) {
            if ($script:FetchProc -and $script:FetchProc.HasExited) {
                Complete-Fetch
            } elseif ($script:FetchStart -and ((Get-Date) - $script:FetchStart).TotalSeconds -gt 45) {
                try { $script:FetchProc.Kill() } catch { }
                Write-Log '取数超时，已中止'
                $script:Fetching = $false
                Set-Status 'error'
                $script:FooterLeftOverride = '更新超时'
            }
        }
        Update-AutoHide
        Update-Footer
    })
$pollTimer.Start()

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds($script:RefreshSeconds)
$refreshTimer.Add_Tick({ Start-Fetch })
$script:RefreshTimer = $refreshTimer
$refreshTimer.Start()

# ------------------------------------------------------------------ 交互

$script:Dragging = $false

# 判断一次按下是否落在可点元素上：往上找带 Tag=noDrag 的祖先。
# 不做这个判断的话，DragMove() 会把鼠标捕获走，按钮的 MouseLeftButtonUp 永远不会触发。
function Test-OnButton($Source) {
    $el = $Source
    $guard = 0
    while ($null -ne $el -and $guard -lt 32) {
        $guard++
        if ($el -is [System.Windows.FrameworkElement]) {
            if ($el.Tag -eq 'noDrag') { return $true }
        }
        if ($el -is [System.Windows.Window]) { break }
        if ($el -is [System.Windows.Media.Visual] -or $el -is [System.Windows.Media.Media3D.Visual3D]) {
            try { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) } catch { break }
        } else {
            break
        }
    }
    return $false
}

function Start-HDrag {
    $script:Dragging = $true
    $script:DragStartCursorX = [System.Windows.Forms.Cursor]::Position.X / ([System.Windows.Media.VisualTreeHelper]::GetDpi($window).DpiScaleX)
    $script:DragStartLeft = [double]$window.Left
    [void]$card.CaptureMouse()
}

function Update-HDrag {
    if (-not $script:Dragging) { return }
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $curX = [System.Windows.Forms.Cursor]::Position.X / $dpi.DpiScaleX
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = $script:DragStartLeft + ($curX - $script:DragStartCursorX)
    $window.Left = [math]::Min([math]::Max($left, $wa.Left), $wa.Right - $window.Width)
}

function End-HDrag {
    if (-not $script:Dragging) { return }
    $script:Dragging = $false
    [void]$card.ReleaseMouseCapture()
    $Config.dockLeft = [math]::Round($window.Left, 1)
    Save-Config $Config
}

$card.Add_MouseLeftButtonDown({
        param($sender, $e)
        if (Test-OnButton $e.OriginalSource) { return }
        if ($script:AutoHideOn) {
            # 贴边状态下只沿顶边左右移动：拖走就没法从顶边滑出来了
            Start-HDrag
        } else {
            try { $window.DragMove() } catch { }
        }
    })
$card.Add_MouseMove({ Update-HDrag })
$card.Add_MouseLeftButtonUp({ End-HDrag })
$tab.Add_MouseLeftButtonDown({ Start-HDrag })

$card.Add_MouseRightButtonUp({
        $script:Menu.IsOpen = $true
    })

# 收起手柄也要能右键（收起时面板看不见，菜单入口只能在手柄上）
$tab.Add_MouseRightButtonUp({
        $script:Menu.IsOpen = $true
    })
$tab.Add_MouseLeftButtonUp({
        if ($script:Dragging) { End-HDrag; return }
        Expand-Panel
        $script:LeaveSince = $null
    })

function Set-BtnHover($Btn, [bool]$On) {
    if ($On) { $Btn.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($P.hover)) }
    else { $Btn.Background = [System.Windows.Media.Brushes]::Transparent }
}
$refreshBtn.Add_MouseEnter({ Set-BtnHover $refreshBtn $true })
$refreshBtn.Add_MouseLeave({ Set-BtnHover $refreshBtn $false })
$refreshBtn.Add_MouseLeftButtonUp({ Start-Fetch })
$closeBtn.Add_MouseEnter({ Set-BtnHover $closeBtn $true })
$closeBtn.Add_MouseLeave({ Set-BtnHover $closeBtn $false })
$closeBtn.Add_MouseLeftButtonUp({ $window.Close() })

# 右键菜单
$menu = New-Object System.Windows.Controls.ContextMenu
$script:Menu = $menu
function New-MenuItem([string]$Header, [scriptblock]$Action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Add_Click($Action)
    return $mi
}
$miRefresh = New-MenuItem '立即刷新' { Start-Fetch }
$miTopmost = New-MenuItem '始终置顶' { }
$miTopmost.IsCheckable = $true
$miTopmost.IsChecked = [bool]$Config.topmost
$miTopmost.Add_Click({
        $Config.topmost = $miTopmost.IsChecked
        $window.Topmost = $miTopmost.IsChecked
        Save-Config $Config
    })
$miReset = New-MenuItem '回到右上角' {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($script:AutoHideOn) {
        $Config.dockLeft = $null
        Set-DockedPosition
    } else {
        $window.Left = $wa.Right - $window.Width - [double]$Config.margin
        $window.Top = $wa.Top + [double]$Config.margin
    }
    $Config.position = $null
    Save-Config $Config
}
$miAutoHide = New-MenuItem '自动收起（贴右上角）' { }
$miAutoHide.IsCheckable = $true
$miAutoHide.IsChecked = [bool]$Config.autoHide
$miAutoHide.Add_Click({
        $Config.autoHide = $miAutoHide.IsChecked
        $script:AutoHideOn = [bool]$miAutoHide.IsChecked
        Save-Config $Config
        Apply-AutoHideMode
        Write-Log ("自动收起: " + $script:AutoHideOn)
    })
$miStartup = New-MenuItem '开机自动启动' { }
$miStartup.IsCheckable = $true
$miStartup.IsChecked = (Test-Path -LiteralPath $StartupLnk)
$miStartup.Add_Click({
        try {
            if ($miStartup.IsChecked) {
                $target = Get-LaunchTarget
                $ws = New-Object -ComObject WScript.Shell
                $lnk = $ws.CreateShortcut($StartupLnk)
                $lnk.TargetPath = $target.Path
                $lnk.Arguments = $target.Args
                $lnk.WorkingDirectory = $Root
                $lnk.Description = '额度挂件'
                $lnk.Save()
                Write-Log ("已设置开机自启 -> {0} {1}" -f $target.Path, $target.Args)
            } else {
                Remove-Item -LiteralPath $StartupLnk -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "设置自启失败: $($_.Exception.Message)"
            $miStartup.IsChecked = -not $miStartup.IsChecked
        }
    })
$miConfig = New-MenuItem '打开配置文件' { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $ConfigPath) }
$miExit = New-MenuItem '退出' { $window.Close() }

$menu.Items.Add($miRefresh) | Out-Null
$menu.Items.Add($miTopmost) | Out-Null
$menu.Items.Add($miAutoHide) | Out-Null
$menu.Items.Add($miReset) | Out-Null
$menu.Items.Add($miStartup) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miConfig) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$card.ContextMenu = $menu
$tab.ContextMenu = $menu

# 首次渲染后定位；高度变化时保持顶边不动
$script:Positioned = $false
$window.Add_ContentRendered({
        if (-not $script:Positioned) {
            $script:Positioned = $true
            $wa = [System.Windows.SystemParameters]::WorkArea
            if ($script:AutoHideOn) {
                Set-DockedPosition
            } else {
                $pos = $Config.position
                if ($pos -and $null -ne $pos.left -and $null -ne $pos.top) {
                    $window.Left = [double]$pos.left
                    $window.Top = [double]$pos.top
                    # 屏幕布局变了就拉回可见区域
                    if ($window.Left -lt $wa.Left -or $window.Left -gt ($wa.Right - 40) -or
                        $window.Top -lt $wa.Top -or $window.Top -gt ($wa.Bottom - 40)) {
                        $window.Left = $wa.Right - $window.Width - [double]$Config.margin
                        $window.Top = $wa.Top + [double]$Config.margin
                    }
                } else {
                    $window.Left = $wa.Right - $window.Width - [double]$Config.margin
                    $window.Top = $wa.Top + [double]$Config.margin
                }
            }
            Apply-AutoHideMode
            Start-Fetch
        }
    })

$window.Add_Closing({
        $pollTimer.Stop()
        $refreshTimer.Stop()
        try {
            if ($script:FetchProc -and -not $script:FetchProc.HasExited) { $script:FetchProc.Kill() }
        } catch { }
        # 自动收起模式下位置是算出来的，不需要记
        if (-not $script:AutoHideOn -and $window.Left -gt -10000) {
            $Config.position = @{ left = [math]::Round($window.Left, 1); top = [math]::Round($window.Top, 1) }
            Save-Config $Config
        }
    })

Write-Log "启动（node=$NodePath, 主题=$($Config.theme), 刷新=$($Config.refreshSeconds)s）"
$lt = Get-LaunchTarget
Write-Log ("运行副本: {0}" -f $Root)
Write-Log ("开机自启目标: {0} {1}" -f $lt.Path, $lt.Args)

# 先显示上次缓存，避免开窗空白
$cached = Read-Json $CacheFile
if ($cached) { Render $cached }

$window.ShowDialog() | Out-Null
