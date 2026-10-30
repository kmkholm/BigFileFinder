#requires -Version 5.1
<#
    BigFileFinder - باحث الملفات الضخمة
    Dr. Mohammed Tawfik - kmkhol01@gmail.com - MIT License
    https://github.com/kmkholm/BigFileFinder

    Finds the huge files Windows Explorer refuses to show or sort, in any folder
    or whole drive, and deletes, moves or exports them. Bilingual interface:
    Arabic (right-to-left) and English, switched from the button in the toolbar.

    واجهة بلغتين: العربية والإنجليزية، تُبدَّل من الزر في شريط الأدوات.

    Usage / الاستخدام:
      BigFileFinder.cmd
      powershell -File BigFileFinder.ps1 -Lang en -Path "D:\" -AutoScan
      powershell -File BigFileFinder.ps1 -NoGui -Path "C:\" -MinSizeMB 500
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [double]$MinSizeMB = 100,
    [int]$Top = 500,
    [string]$Csv = '',
    [switch]$NoGui,
    [switch]$AutoScan,
    [string]$Shot = '',
    [ValidateSet('ar','en')]
    [string]$Lang = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ------------------------------------------------------------------
#  محرك الفحص (C# لأن PowerShell بطيء جداً مع ملايين الملفات)
# ------------------------------------------------------------------
$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

public class BigFileScanner
{
    public class Item
    {
        public string Name;
        public string Folder;
        public string FullPath;
        public long   SizeBytes;
        public DateTime Modified;
        public string Ext;
    }

    public class DirItem
    {
        public string FullPath;
        public long   SizeBytes;
        public int    FileCount;
    }

    public long Scanned;
    public long TotalBytes;
    public int  Denied;
    public int  MaxItems = 300000;
    public bool Truncated;
    public volatile bool Cancel;
    public volatile bool Done;
    public volatile string Current = "";
    public volatile string Error = "";

    public List<Item> Files = new List<Item>();
    public Dictionary<string, long> DirSizes  = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, int>  DirCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

    static string ToLong(string p)
    {
        if (p.Length < 240 || p.StartsWith(@"\\?\")) return p;
        if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
        return @"\\?\" + p;
    }

    static string Strip(string p)
    {
        if (string.IsNullOrEmpty(p)) return "";
        if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
        if (p.StartsWith(@"\\?\")) return p.Substring(4);
        return p;
    }

    public void StartAsync(string root, long minBytes)
    {
        Done = false; Cancel = false; Error = "";
        Scanned = 0; TotalBytes = 0; Denied = 0; Truncated = false;
        Files.Clear(); DirSizes.Clear(); DirCounts.Clear();
        Thread t = new Thread(delegate()
        {
            try { Scan(root, minBytes); }
            catch (Exception ex) { Error = ex.Message; }
            finally { Done = true; }
        });
        t.IsBackground = true;
        t.Start();
    }

    public void Scan(string root, long minBytes)
    {
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0 && !Cancel)
        {
            string dir = stack.Pop();
            Current = dir;
            long own = 0; int cnt = 0;
            try
            {
                DirectoryInfo di = new DirectoryInfo(ToLong(dir));
                foreach (FileSystemInfo info in di.EnumerateFileSystemInfos())
                {
                    if (Cancel) break;
                    FileAttributes a;
                    try { a = info.Attributes; } catch { continue; }
                    if ((a & FileAttributes.ReparsePoint) != 0) continue;
                    if ((a & FileAttributes.Directory) != 0) { stack.Push(Strip(info.FullName)); continue; }

                    FileInfo fi = info as FileInfo;
                    if (fi == null) continue;
                    long len;
                    try { len = fi.Length; } catch { continue; }

                    Scanned++; TotalBytes += len; own += len; cnt++;
                    if (len >= minBytes)
                    {
                        if (Files.Count < MaxItems)
                        {
                            Item it = new Item();
                            it.Name = fi.Name;
                            it.Folder = Strip(fi.DirectoryName);
                            it.FullPath = Strip(fi.FullName);
                            it.SizeBytes = len;
                            it.Ext = fi.Extension.ToLowerInvariant();
                            try { it.Modified = fi.LastWriteTime; } catch { it.Modified = DateTime.MinValue; }
                            lock (Files) { Files.Add(it); }
                        }
                        else Truncated = true;
                    }
                }
            }
            catch (Exception) { Denied++; }

            if (cnt > 0) { DirSizes[dir] = own; DirCounts[dir] = cnt; }
        }
    }

    public Item[] TopFiles(int n)
    {
        Item[] arr;
        lock (Files) { arr = Files.ToArray(); }
        Array.Sort(arr, delegate(Item x, Item y) { return y.SizeBytes.CompareTo(x.SizeBytes); });
        if (n > 0 && arr.Length > n)
        {
            Item[] r = new Item[n];
            Array.Copy(arr, r, n);
            return r;
        }
        return arr;
    }

    public DirItem[] TopFolders(string root, int n)
    {
        Dictionary<string, long> roll = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, int>  cnts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        string rootNorm = root.TrimEnd('\\');

        foreach (KeyValuePair<string, long> kv in DirSizes)
        {
            long sz = kv.Value;
            int c = DirCounts.ContainsKey(kv.Key) ? DirCounts[kv.Key] : 0;
            string p = kv.Key;
            while (!string.IsNullOrEmpty(p))
            {
                if (roll.ContainsKey(p)) { roll[p] += sz; cnts[p] += c; }
                else { roll[p] = sz; cnts[p] = c; }
                if (p.TrimEnd('\\').Length <= rootNorm.Length) break;
                string parent = System.IO.Path.GetDirectoryName(p);
                if (string.IsNullOrEmpty(parent) || parent.Length >= p.Length) break;
                p = parent;
            }
        }

        List<DirItem> list = new List<DirItem>();
        foreach (KeyValuePair<string, long> kv in roll)
        {
            DirItem d = new DirItem();
            d.FullPath = kv.Key;
            d.SizeBytes = kv.Value;
            d.FileCount = cnts[kv.Key];
            list.Add(d);
        }
        list.Sort(delegate(DirItem x, DirItem y) { return y.SizeBytes.CompareTo(x.SizeBytes); });
        if (n > 0 && list.Count > n) list.RemoveRange(n, list.Count - n);
        return list.ToArray();
    }
}
'@

if (-not ('BigFileScanner' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

# ------------------------------------------------------------------
#  دوال مساعدة
# ------------------------------------------------------------------
function Format-Size {
    param([long]$b)
    if ($b -ge 1TB) { return ('{0:N2} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ("$b B")
}

function Get-ShortPath {
    param([string]$p, [int]$max = 75)
    if (-not $p) { return '' }
    if ($p.Length -le $max) { return $p }
    return '...' + $p.Substring($p.Length - $max)
}

function Get-DriveInfoText {
    param([string]$p)
    try {
        $rootp = [System.IO.Path]::GetPathRoot($p)
        if (-not $rootp) { return '' }
        $d = New-Object System.IO.DriveInfo ($rootp)
        if (-not $d.IsReady) { return '' }
        $used = $d.TotalSize - $d.TotalFreeSpace
        return ($script:L.DriveFmt -f $d.Name, (Format-Size $used), (Format-Size $d.TotalSize), (Format-Size $d.TotalFreeSpace))
    } catch { return '' }
}

function Test-ExtMatch {
    param([string]$ext, [string[]]$wanted)
    if (-not $wanted -or $wanted.Count -eq 0) { return $true }
    $e = $ext.TrimStart('.').ToLower()
    foreach ($w in $wanted) { if ($e -eq $w) { return $true } }
    return $false
}

# ==================================================================
#  اللغة / Language
# ==================================================================
function Get-LangFile {
    $dir = Join-Path $env:LOCALAPPDATA 'BigFileFinder'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    return (Join-Path $dir 'lang.txt')
}

function Resolve-Lang {
    param([string]$Requested)
    if ($Requested) { return $Requested.ToLower() }
    try {
        $lf = Get-LangFile
        if (Test-Path -LiteralPath $lf) {
            $v = ([string](Get-Content -LiteralPath $lf -Raw)).Trim().ToLower()
            if ($v -eq 'en' -or $v -eq 'ar') { return $v }
        }
    } catch { }
    # لا يوجد اختيار محفوظ: اتبع لغة النظام / no saved choice: follow the system language
    try {
        if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ar') { return 'ar' }
    } catch { }
    return 'en'
}

function Save-Lang {
    param([string]$v)
    try { [System.IO.File]::WriteAllText((Get-LangFile), $v, [System.Text.Encoding]::ASCII) } catch { }
}

function Get-Strings {
    param([string]$lang)
    if ($lang -eq 'en') {
        return @{
            WinTitle   = 'BigFileFinder - Dr. Mohammed Tawfik'
            AppName    = 'BigFileFinder'
            Tagline    = 'Disk space analysis and cleanup - version {0}'
            LangBtn    = 'عربي'
            PathLbl    = 'Path:'
            Browse     = 'Browse'
            Admin      = 'Run as admin'
            About      = 'About'
            MinSizeLbl = 'Min size (MB):'
            RowsLbl    = 'Rows:'
            Scan       = 'Scan'
            Stop       = 'Stop'
            SearchLbl  = 'Search:'
            ExtLbl     = 'Extensions:'
            TipExt     = 'e.g. mp4;iso;zip;pdf   (empty = all types)'
            TipFilter  = 'any text inside the file path'
            TabFiles   = '  Largest files  '
            TabDirs    = '  Largest folders  '
            ColName    = 'File name'
            ColSize    = 'Size'
            ColType    = 'Type'
            ColMod     = 'Modified'
            ColDir     = 'Folder'
            ColDPath   = 'Folder'
            ColDSize   = 'Total size'
            ColDCnt    = 'Files'
            Open       = 'Open location'
            CopyPath   = 'Copy path'
            ExportCsv  = 'Export CSV'
            MoveTo     = 'Move to folder'
            Recycle    = 'Delete to Recycle Bin'
            Perm       = 'Delete permanently'
            Leg1       = 'over 5 GB'
            Leg2       = 'over 1 GB'
            Leg3       = 'over 200 MB'
            Ready      = 'Ready - choose a path, then click Scan'
            Scanning   = 'Scanning...  {0:N0} files   |   {1}   |   large files: {2:N0}   |   {3}'
            Finished   = 'Finished: {0:N0} files / {1} in {2:N1} s - protected folders skipped: {3}{4}'
            Showing    = 'Showing {0:N0} files, {1}   |   total results {2:N0}   |   {3}'
            Capped     = '   (result cap reached - raise Min size)'
            ErrPrefix  = '   Error: '
            Copied     = '{0} path(s) copied to the clipboard.'
            ExportedTo = 'Exported to: '
            DriveFmt   = 'Drive {0}  {1} used of {2} - {3} free'
            WarnTitle  = 'Notice'
            ErrTitle   = 'Error'
            ResTitle   = 'Result'
            ConfTitle  = 'Confirm delete'
            PickPath   = 'Choose a path first.'
            NoPath     = 'Path not found:'
            SelectOne  = 'Select at least one item.'
            NoResults  = 'No results to export.'
            BrowseDesc = 'Choose the folder or drive to scan'
            DestDesc   = 'Choose the destination folder'
            KindRecyc  = 'to the Recycle Bin'
            KindPerm   = 'permanently (this cannot be undone)'
            DelHead    = '{0} item(s), {1}, will be deleted {2}'
            AndMore    = '... and {0} more'
            Proceed    = 'Do you want to continue?'
            DelDone    = 'Deleted {0} item(s) - {1} freed'
            FailHead   = '{0} item(s) failed:'
            MoveDone   = 'Moved {0} item(s) to: {1}'
            AdminFail  = 'Could not restart as administrator.'
            AboutBody  = 'BigFileFinder - version {0}{1}{1}By: Dr. Mohammed Tawfik{1}{2}{1}{1}Finds the huge files Windows Explorer refuses to show or sort, and deletes or moves them.'
            CScan      = 'Scanning: {0}   (min size {1} MB)'
            CDone      = 'Scanned {0:N0} files, {1}, in {2:N1} s - protected folders skipped: {3}'
            CDirs      = 'Largest folders:'
            CNoPath    = 'Use -Path to specify the folder in text mode.'
            CBadPath   = 'Path not found: '
        }
    }
    return @{
        WinTitle   = 'باحث الملفات الضخمة — د. محمد توفيق'
        AppName    = 'باحث الملفات الضخمة'
        Tagline    = 'تحليل المساحة وتنظيف الأقراص — إصدار {0}'
        LangBtn    = 'English'
        PathLbl    = 'المسار:'
        Browse     = 'استعراض'
        Admin      = 'تشغيل كمسؤول'
        About      = 'عن البرنامج'
        MinSizeLbl = 'أصغر حجم (م.ب):'
        RowsLbl    = 'عدد النتائج:'
        Scan       = 'ابدأ الفحص'
        Stop       = 'إيقاف'
        SearchLbl  = 'بحث:'
        ExtLbl     = 'امتدادات:'
        TipExt     = 'مثال: mp4;iso;zip;pdf   (فارغ = كل الأنواع)'
        TipFilter  = 'أي نص داخل مسار الملف'
        TabFiles   = '  أكبر الملفات  '
        TabDirs    = '  أكبر المجلدات  '
        ColName    = 'اسم الملف'
        ColSize    = 'الحجم'
        ColType    = 'النوع'
        ColMod     = 'آخر تعديل'
        ColDir     = 'المجلد'
        ColDPath   = 'المجلد'
        ColDSize   = 'الحجم الكلي'
        ColDCnt    = 'عدد الملفات'
        Open       = 'فتح الموقع'
        CopyPath   = 'نسخ المسار'
        ExportCsv  = 'تصدير CSV'
        MoveTo     = 'نقل إلى مجلد'
        Recycle    = 'حذف إلى سلة المحذوفات'
        Perm       = 'حذف نهائي'
        Leg1       = 'أكبر من 5 ج.ب'
        Leg2       = 'أكبر من 1 ج.ب'
        Leg3       = 'أكبر من 200 م.ب'
        Ready      = 'جاهز — اختر مساراً ثم اضغط «ابدأ الفحص»'
        Scanning   = 'جارٍ الفحص...  {0:N0} ملف   |   {1}   |   ملفات كبيرة: {2:N0}   |   {3}'
        Finished   = 'انتهى الفحص: {0:N0} ملف / {1} خلال {2:N1} ثانية — مجلدات محمية تم تخطيها: {3}{4}'
        Showing    = 'معروض {0:N0} ملف بحجم {1}   |   إجمالي النتائج {2:N0}   |   {3}'
        Capped     = '   (بلغت الحد الأقصى — ارفع «أصغر حجم»)'
        ErrPrefix  = '   خطأ: '
        Copied     = 'تم نسخ {0} مسار إلى الحافظة.'
        ExportedTo = 'تم التصدير إلى: '
        DriveFmt   = 'القرص {0} مستخدم {1} من {2} — متبقٍ {3}'
        WarnTitle  = 'تنبيه'
        ErrTitle   = 'خطأ'
        ResTitle   = 'النتيجة'
        ConfTitle  = 'تأكيد الحذف'
        PickPath   = 'اختر مساراً أولاً.'
        NoPath     = 'المسار غير موجود:'
        SelectOne  = 'حدد عنصراً واحداً على الأقل.'
        NoResults  = 'لا توجد نتائج للتصدير.'
        BrowseDesc = 'اختر المجلد أو القرص المراد فحصه'
        DestDesc   = 'اختر مجلد الوجهة'
        KindRecyc  = 'إلى سلة المحذوفات'
        KindPerm   = 'حذفاً نهائياً (لا يمكن التراجع)'
        DelHead    = 'سيتم حذف {0} عنصراً بحجم {1} {2}'
        AndMore    = '... و {0} عنصراً آخر'
        Proceed    = 'هل تريد المتابعة؟'
        DelDone    = 'تم حذف {0} عنصراً — تحرير {1}'
        FailHead   = 'فشل {0} عنصراً:'
        MoveDone   = 'تم نقل {0} عنصراً إلى: {1}'
        AdminFail  = 'تعذّر التشغيل كمسؤول.'
        AboutBody  = 'باحث الملفات الضخمة — إصدار {0}{1}{1}إعداد: د. محمد توفيق{1}{2}{1}{1}أداة تجد الملفات الضخمة التي لا يُظهرها مستكشف ويندوز ولا يرتّبها، وتحذفها أو تنقلها.'
        CScan      = 'فحص: {0}   (أصغر حجم {1} م.ب)'
        CDone      = 'تم فحص {0:N0} ملف بحجم {1} خلال {2:N1} ثانية — مجلدات محمية تم تخطيها: {3}'
        CDirs      = 'أكبر المجلدات:'
        CNoPath    = 'استخدم -Path لتحديد المسار في الوضع النصي.'
        CBadPath   = 'المسار غير موجود: '
    }
}

$script:AUTHOR_NAME = 'Dr. Mohammed Tawfik'
$script:AUTHOR_AR   = 'د. محمد توفيق'
$script:AUTHOR_MAIL = 'kmkhol01@gmail.com'
$script:APP_VERSION = '1.2'
$script:UILang      = Resolve-Lang $Lang
$script:L           = Get-Strings $script:UILang

# ==================================================================
#  الوضع النصي (بدون واجهة) / Text mode
# ==================================================================
function Invoke-ConsoleScan {
    param([string]$Root, [double]$MinMB, [int]$TopN, [string]$CsvOut)

    $L = $script:L
    if (-not (Test-Path -LiteralPath $Root)) { throw ($L.CBadPath + $Root) }
    $minBytes = [long]($MinMB * 1MB)
    Write-Host ($L.CScan -f $Root, $MinMB) -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sc = New-Object BigFileScanner
    $sc.Scan($Root, $minBytes)
    $sw.Stop()

    Write-Host ($L.CDone -f $sc.Scanned, (Format-Size $sc.TotalBytes), $sw.Elapsed.TotalSeconds, $sc.Denied) -ForegroundColor Green

    $rows = foreach ($f in $sc.TopFiles($TopN)) {
        [PSCustomObject]@{
            Size     = (Format-Size $f.SizeBytes)
            Bytes    = $f.SizeBytes
            Modified = $f.Modified.ToString('yyyy-MM-dd')
            FullPath = $f.FullPath
        }
    }
    $rows | Select-Object -First 60 | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    Write-Host $L.CDirs -ForegroundColor Cyan
    $sc.TopFolders($Root, 25) | ForEach-Object {
        [PSCustomObject]@{ Size = (Format-Size $_.SizeBytes); Files = $_.FileCount; Folder = $_.FullPath }
    } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    if ($CsvOut) {
        $rows | Export-Csv -LiteralPath $CsvOut -NoTypeInformation -Encoding UTF8
        Write-Host ($L.ExportedTo + $CsvOut) -ForegroundColor Yellow
    }
}

# ==================================================================
#  الواجهة الرسومية / Graphical interface
# ==================================================================
function Show-BigFileFinder {
    param([switch]$BuildOnly)

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $L = $script:L
    $isAr = ($script:UILang -eq 'ar')

    # ---------- لوحة الألوان / palette ----------
    $C_Dark   = [System.Drawing.Color]::FromArgb(15, 44, 77)
    $C_Dark2  = [System.Drawing.Color]::FromArgb(24, 66, 110)
    $C_Accent = [System.Drawing.Color]::FromArgb(45, 125, 210)
    $C_Bar    = [System.Drawing.Color]::FromArgb(243, 246, 250)
    $C_Line   = [System.Drawing.Color]::FromArgb(214, 222, 232)
    $C_Teal   = [System.Drawing.Color]::FromArgb(0, 121, 107)
    $C_Green  = [System.Drawing.Color]::FromArgb(27, 120, 70)
    $C_Orange = [System.Drawing.Color]::FromArgb(214, 93, 14)
    $C_Red    = [System.Drawing.Color]::FromArgb(183, 28, 28)
    $C_Gray   = [System.Drawing.Color]::FromArgb(96, 104, 115)
    $C_Gold   = [System.Drawing.Color]::FromArgb(176, 124, 20)
    $C_White  = [System.Drawing.Color]::White
    $C_SubTxt = [System.Drawing.Color]::FromArgb(158, 195, 232)

    $T1_BG = [System.Drawing.Color]::FromArgb(253, 226, 228); $T1_FG = [System.Drawing.Color]::FromArgb(150, 20, 20)
    $T2_BG = [System.Drawing.Color]::FromArgb(255, 238, 213); $T2_FG = [System.Drawing.Color]::FromArgb(150, 75, 0)
    $T3_BG = [System.Drawing.Color]::FromArgb(255, 250, 212); $T3_FG = [System.Drawing.Color]::FromArgb(90, 80, 0)
    $D1_BG = [System.Drawing.Color]::FromArgb(209, 231, 255); $D1_FG = [System.Drawing.Color]::FromArgb(10, 60, 110)
    $D2_BG = [System.Drawing.Color]::FromArgb(233, 242, 255); $D2_FG = [System.Drawing.Color]::FromArgb(20, 70, 120)

    $script:Results   = @()
    $script:Folders   = @()
    $script:Scanner   = $null
    $script:Root      = ''
    $script:Stopwatch = $null
    $script:AutoStart = ($AutoScan -or ($Path -ne ''))

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $L.WinTitle
    $form.Size = New-Object System.Drawing.Size(1200, 780)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize = New-Object System.Drawing.Size(1020, 600)
    $form.BackColor = $C_Bar
    if ($isAr) {
        $form.RightToLeft = 'Yes'
        $form.RightToLeftLayout = $true
    } else {
        $form.RightToLeft = 'No'
        $form.RightToLeftLayout = $false
    }

    # ================= الترويسة / header =================
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Dock = 'Top'; $hdr.Height = 60; $hdr.BackColor = $C_Dark
    $form.Controls.Add($hdr)

    $lblLogo = New-Object System.Windows.Forms.Label
    $lblLogo.Text = $L.AppName
    $lblLogo.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblLogo.ForeColor = $C_White
    $lblLogo.AutoSize = $true
    $lblLogo.Location = New-Object System.Drawing.Point(16, 9)
    $hdr.Controls.Add($lblLogo)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = ($L.Tagline -f $script:APP_VERSION)
    $lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblSub.ForeColor = $C_SubTxt
    $lblSub.AutoSize = $true
    $lblSub.Location = New-Object System.Drawing.Point(18, 38)
    $hdr.Controls.Add($lblSub)

    $lblAuthor = New-Object System.Windows.Forms.Label
    $lblAuthor.Text = $script:AUTHOR_AR + '   |   ' + $script:AUTHOR_NAME
    $lblAuthor.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblAuthor.ForeColor = $C_White
    $lblAuthor.TextAlign = 'MiddleRight'
    $lblAuthor.Location = New-Object System.Drawing.Point(700, 10)
    $lblAuthor.Size = New-Object System.Drawing.Size(360, 20)
    $lblAuthor.Anchor = 'Top,Right'
    $hdr.Controls.Add($lblAuthor)

    $lblMail = New-Object System.Windows.Forms.Label
    $lblMail.Text = $script:AUTHOR_MAIL
    $lblMail.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblMail.ForeColor = $C_SubTxt
    $lblMail.TextAlign = 'MiddleRight'
    $lblMail.Location = New-Object System.Drawing.Point(700, 32)
    $lblMail.Size = New-Object System.Drawing.Size(360, 18)
    $lblMail.Anchor = 'Top,Right'
    $hdr.Controls.Add($lblMail)

    # ================= شريط الأدوات / toolbar =================
    $pTop = New-Object System.Windows.Forms.Panel
    $pTop.Dock = 'Top'; $pTop.Height = 84; $pTop.BackColor = $C_White
    $form.Controls.Add($pTop)

    function New-Lbl {
        param([string]$text, [int]$x, [int]$y, [int]$w)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, 20)
        $l.ForeColor = [System.Drawing.Color]::FromArgb(60, 70, 85)
        $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $pTop.Controls.Add($l)
        return $l
    }

    function Style-Button {
        param($b, $bg, $fg)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $bg
        $b.ForeColor = $fg
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    }

    [void](New-Lbl $L.PathLbl 12 15 50)

    $script:txtPath = New-Object System.Windows.Forms.TextBox
    $script:txtPath.Location = New-Object System.Drawing.Point(66, 12)
    $script:txtPath.Size = New-Object System.Drawing.Size(634, 25)
    $script:txtPath.Anchor = 'Top,Left,Right'
    $script:txtPath.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $script:txtPath.BorderStyle = 'FixedSingle'
    $script:txtPath.RightToLeft = 'No'
    $pTop.Controls.Add($script:txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = $L.Browse
    $btnBrowse.Location = New-Object System.Drawing.Point(708, 11)
    $btnBrowse.Size = New-Object System.Drawing.Size(84, 27)
    $btnBrowse.Anchor = 'Top,Right'
    Style-Button $btnBrowse $C_Accent $C_White
    $pTop.Controls.Add($btnBrowse)

    $btnAdmin = New-Object System.Windows.Forms.Button
    $btnAdmin.Text = $L.Admin
    $btnAdmin.Location = New-Object System.Drawing.Point(798, 11)
    $btnAdmin.Size = New-Object System.Drawing.Size(112, 27)
    $btnAdmin.Anchor = 'Top,Right'
    Style-Button $btnAdmin $C_Gray $C_White
    $pTop.Controls.Add($btnAdmin)

    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.Text = $L.About
    $btnAbout.Location = New-Object System.Drawing.Point(916, 11)
    $btnAbout.Size = New-Object System.Drawing.Size(86, 27)
    $btnAbout.Anchor = 'Top,Right'
    Style-Button $btnAbout $C_Dark2 $C_White
    $pTop.Controls.Add($btnAbout)

    $btnLang = New-Object System.Windows.Forms.Button
    $btnLang.Text = $L.LangBtn
    $btnLang.Location = New-Object System.Drawing.Point(1008, 11)
    $btnLang.Size = New-Object System.Drawing.Size(64, 27)
    $btnLang.Anchor = 'Top,Right'
    Style-Button $btnLang $C_Gold $C_White
    $pTop.Controls.Add($btnLang)

    [void](New-Lbl $L.MinSizeLbl 12 51 104)

    $script:numMin = New-Object System.Windows.Forms.NumericUpDown
    $script:numMin.Location = New-Object System.Drawing.Point(120, 48)
    $script:numMin.Size = New-Object System.Drawing.Size(76, 25)
    $script:numMin.Maximum = 1000000
    $script:numMin.Minimum = 0
    $script:numMin.Increment = 50
    $script:numMin.Value = [decimal]$MinSizeMB
    $script:numMin.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $pTop.Controls.Add($script:numMin)

    [void](New-Lbl $L.RowsLbl 206 51 78)

    $script:numTop = New-Object System.Windows.Forms.NumericUpDown
    $script:numTop.Location = New-Object System.Drawing.Point(288, 48)
    $script:numTop.Size = New-Object System.Drawing.Size(72, 25)
    $script:numTop.Maximum = 100000
    $script:numTop.Minimum = 10
    $script:numTop.Increment = 100
    $script:numTop.Value = [decimal]$Top
    $script:numTop.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $pTop.Controls.Add($script:numTop)

    $script:btnScan = New-Object System.Windows.Forms.Button
    $script:btnScan.Text = $L.Scan
    $script:btnScan.Location = New-Object System.Drawing.Point(372, 47)
    $script:btnScan.Size = New-Object System.Drawing.Size(104, 28)
    Style-Button $script:btnScan $C_Green $C_White
    $pTop.Controls.Add($script:btnScan)

    $script:btnStop = New-Object System.Windows.Forms.Button
    $script:btnStop.Text = $L.Stop
    $script:btnStop.Location = New-Object System.Drawing.Point(482, 47)
    $script:btnStop.Size = New-Object System.Drawing.Size(74, 28)
    $script:btnStop.Enabled = $false
    Style-Button $script:btnStop $C_Gray $C_White
    $pTop.Controls.Add($script:btnStop)

    [void](New-Lbl $L.SearchLbl 568 51 54)

    $script:txtFilter = New-Object System.Windows.Forms.TextBox
    $script:txtFilter.Location = New-Object System.Drawing.Point(626, 48)
    $script:txtFilter.Size = New-Object System.Drawing.Size(150, 25)
    $script:txtFilter.BorderStyle = 'FixedSingle'
    $pTop.Controls.Add($script:txtFilter)

    [void](New-Lbl $L.ExtLbl 784 51 76)

    $script:txtExt = New-Object System.Windows.Forms.TextBox
    $script:txtExt.Location = New-Object System.Drawing.Point(864, 48)
    $script:txtExt.Size = New-Object System.Drawing.Size(208, 25)
    $script:txtExt.BorderStyle = 'FixedSingle'
    $script:txtExt.Anchor = 'Top,Right'
    $pTop.Controls.Add($script:txtExt)

    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($script:txtExt, $L.TipExt)
    $tt.SetToolTip($script:txtFilter, $L.TipFilter)

    $sep = New-Object System.Windows.Forms.Label
    $sep.Dock = 'Top'; $sep.Height = 1; $sep.BackColor = $C_Line
    $pTop.Controls.Add($sep)

    # ================= الشريط السفلي / bottom bar =================
    $pBot = New-Object System.Windows.Forms.Panel
    $pBot.Dock = 'Bottom'; $pBot.Height = 96; $pBot.BackColor = $C_White
    $form.Controls.Add($pBot)

    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.Location = New-Object System.Drawing.Point(12, 8)
    $script:lblStatus.Size = New-Object System.Drawing.Size(1160, 18)
    $script:lblStatus.Anchor = 'Top,Left,Right'
    $script:lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:lblStatus.ForeColor = $C_Dark
    $script:lblStatus.Text = $L.Ready
    $pBot.Controls.Add($script:lblStatus)

    $script:prog = New-Object System.Windows.Forms.ProgressBar
    $script:prog.Location = New-Object System.Drawing.Point(12, 29)
    $script:prog.Size = New-Object System.Drawing.Size(1160, 6)
    $script:prog.Anchor = 'Top,Left,Right'
    $script:prog.Style = 'Marquee'
    $script:prog.MarqueeAnimationSpeed = 0
    $pBot.Controls.Add($script:prog)

    $script:bx = 12
    function New-BottomButton {
        param([string]$text, [int]$w, $bg)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Location = New-Object System.Drawing.Point($script:bx, 42)
        $b.Size = New-Object System.Drawing.Size($w, 30)
        Style-Button $b $bg ([System.Drawing.Color]::White)
        $pBot.Controls.Add($b)
        $script:bx = $script:bx + $w + 7
        return $b
    }

    $btnOpen  = New-BottomButton $L.Open      112 $C_Accent
    $btnCopy  = New-BottomButton $L.CopyPath  108 $C_Accent
    $btnCsv   = New-BottomButton $L.ExportCsv 104 $C_Teal
    $btnMove  = New-BottomButton $L.MoveTo    120 $C_Green
    $btnRecyc = New-BottomButton $L.Recycle   178 $C_Orange
    $btnPerm  = New-BottomButton $L.Perm      150 $C_Red

    function New-Legend {
        param([string]$text, $bg, $fg, [int]$w)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.BackColor = $bg
        $l.ForeColor = $fg
        $l.TextAlign = 'MiddleCenter'
        $l.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        $l.Location = New-Object System.Drawing.Point($script:bx, 47)
        $l.Size = New-Object System.Drawing.Size($w, 20)
        $l.BorderStyle = 'FixedSingle'
        $pBot.Controls.Add($l)
        $script:bx = $script:bx + $w + 4
        return $l
    }
    $script:bx = $script:bx + 10
    [void](New-Legend $L.Leg1 $T1_BG $T1_FG 92)
    [void](New-Legend $L.Leg2 $T2_BG $T2_FG 92)
    [void](New-Legend $L.Leg3 $T3_BG $T3_FG 104)

    $lblCredit = New-Object System.Windows.Forms.Label
    $lblCredit.Text = $script:AUTHOR_AR + ' — ' + $script:AUTHOR_MAIL
    if (-not $isAr) { $lblCredit.Text = $script:AUTHOR_NAME + ' — ' + $script:AUTHOR_MAIL }
    $lblCredit.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblCredit.ForeColor = [System.Drawing.Color]::FromArgb(130, 140, 155)
    $lblCredit.TextAlign = 'MiddleRight'
    $lblCredit.Location = New-Object System.Drawing.Point(862, 76)
    $lblCredit.Size = New-Object System.Drawing.Size(310, 16)
    $lblCredit.Anchor = 'Top,Right'
    $pBot.Controls.Add($lblCredit)

    # ================= الجداول / grids =================
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($tabs)
    $tabs.BringToFront()
    $hdr.SendToBack()

    $t1 = New-Object System.Windows.Forms.TabPage; $t1.Text = $L.TabFiles; $t1.BackColor = $C_White
    $t2 = New-Object System.Windows.Forms.TabPage; $t2.Text = $L.TabDirs;  $t2.BackColor = $C_White
    $tabs.TabPages.Add($t1)
    $tabs.TabPages.Add($t2)

    function New-Grid {
        $g = New-Object System.Windows.Forms.DataGridView
        $g.Dock = 'Fill'
        $g.ReadOnly = $true
        $g.AllowUserToAddRows = $false
        $g.AllowUserToDeleteRows = $false
        $g.AllowUserToResizeRows = $false
        $g.RowHeadersVisible = $false
        $g.SelectionMode = 'FullRowSelect'
        $g.MultiSelect = $true
        $g.BackgroundColor = [System.Drawing.Color]::White
        $g.BorderStyle = 'None'
        $g.GridColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $g.CellBorderStyle = 'SingleHorizontal'
        $g.RowTemplate.Height = 25
        $g.RightToLeft = 'No'
        $g.EnableHeadersVisualStyles = $false
        $g.ColumnHeadersHeight = 32
        $g.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(15, 44, 77)
        $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
        $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(15, 44, 77)
        $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        $g.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
        $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(197, 222, 247)
        $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
        $g.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
        return $g
    }

    function Add-Col {
        param($grid, [string]$name, [string]$header, [int]$width, [bool]$visible = $true, [bool]$bold = $false)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $name
        $c.HeaderText = $header
        $c.Width = $width
        $c.Visible = $visible
        if ($bold) {
            $c.DefaultCellStyle.Font = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Bold)
            $c.DefaultCellStyle.Alignment = 'MiddleRight'
        }
        [void]$grid.Columns.Add($c)
    }

    $script:dgvF = New-Grid
    Add-Col $script:dgvF 'colName'  $L.ColName 290 $true  $false
    Add-Col $script:dgvF 'colSize'  $L.ColSize 100 $true  $true
    Add-Col $script:dgvF 'colExt'   $L.ColType  70 $true  $false
    Add-Col $script:dgvF 'colMod'   $L.ColMod  120 $true  $false
    Add-Col $script:dgvF 'colDir'   $L.ColDir  530 $true  $false
    Add-Col $script:dgvF 'colBytes' 'bytes'     10 $false $false
    Add-Col $script:dgvF 'colFull'  'full'      10 $false $false
    $t1.Controls.Add($script:dgvF)

    $script:dgvD = New-Grid
    Add-Col $script:dgvD 'colDPath'  $L.ColDPath 770 $true  $false
    Add-Col $script:dgvD 'colDSize'  $L.ColDSize 120 $true  $true
    Add-Col $script:dgvD 'colDCnt'   $L.ColDCnt  110 $true  $false
    Add-Col $script:dgvD 'colDBytes' 'bytes'      10 $false $false
    $t2.Controls.Add($script:dgvD)

    $sortHandler = {
        param($s, $e)
        $hidden = ''
        if ($e.Column.Name -eq 'colSize')  { $hidden = 'colBytes' }
        if ($e.Column.Name -eq 'colDSize') { $hidden = 'colDBytes' }
        if ($hidden) {
            $a = [long]$s.Rows[$e.RowIndex1].Cells[$hidden].Value
            $b = [long]$s.Rows[$e.RowIndex2].Cells[$hidden].Value
            $e.SortResult = $a.CompareTo($b)
            $e.Handled = $true
        }
    }
    $script:dgvF.add_SortCompare($sortHandler)
    $script:dgvD.add_SortCompare($sortHandler)

    # ---------- تعبئة الجداول / fill ----------
    function Update-FilesGrid {
        $exts = @()
        $raw = $script:txtExt.Text.Trim()
        if ($raw) { $exts = @($raw -split '[;,\s]+' | Where-Object { $_ } | ForEach-Object { $_.TrimStart('.').ToLower() }) }
        $needle = $script:txtFilter.Text.Trim()
        $limit = [int]$script:numTop.Value

        $script:dgvF.SuspendLayout()
        $script:dgvF.Rows.Clear()
        $n = 0
        $sum = [long]0
        foreach ($it in $script:Results) {
            if ($n -ge $limit) { break }
            if (-not (Test-ExtMatch $it.Ext $exts)) { continue }
            if ($needle -and ($it.FullPath.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            $mod = ''
            try { $mod = $it.Modified.ToString('yyyy-MM-dd HH:mm') } catch { }
            $i = $script:dgvF.Rows.Add($it.Name, (Format-Size $it.SizeBytes), $it.Ext, $mod, $it.Folder, $it.SizeBytes, $it.FullPath)
            $st = $script:dgvF.Rows[$i].DefaultCellStyle
            if ($it.SizeBytes -ge 5GB)        { $st.BackColor = $T1_BG; $st.ForeColor = $T1_FG }
            elseif ($it.SizeBytes -ge 1GB)    { $st.BackColor = $T2_BG; $st.ForeColor = $T2_FG }
            elseif ($it.SizeBytes -ge 200MB)  { $st.BackColor = $T3_BG; $st.ForeColor = $T3_FG }
            $n++
            $sum = $sum + $it.SizeBytes
        }
        $script:dgvF.ResumeLayout()
        $script:lblStatus.Text = ($script:L.Showing -f $n, (Format-Size $sum), $script:Results.Count, (Get-DriveInfoText $script:Root))
    }

    function Update-FoldersGrid {
        $script:dgvD.SuspendLayout()
        $script:dgvD.Rows.Clear()
        $i = 0
        foreach ($d in $script:Folders) {
            if ($i -ge 400) { break }
            $r = $script:dgvD.Rows.Add($d.FullPath, (Format-Size $d.SizeBytes), ('{0:N0}' -f $d.FileCount), $d.SizeBytes)
            $st = $script:dgvD.Rows[$r].DefaultCellStyle
            if ($d.SizeBytes -ge 20GB)     { $st.BackColor = $D1_BG; $st.ForeColor = $D1_FG }
            elseif ($d.SizeBytes -ge 5GB)  { $st.BackColor = $D2_BG; $st.ForeColor = $D2_FG }
            $i++
        }
        $script:dgvD.ResumeLayout()
    }

    # ---------- الفحص / scanning ----------
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 300

    function Stop-ScanUI {
        $script:timer.Stop()
        $script:prog.MarqueeAnimationSpeed = 0
        $script:btnScan.Enabled = $true
        $script:btnStop.Enabled = $false
    }

    function Complete-Scan {
        $s = $script:Scanner
        Stop-ScanUI
        if ($null -eq $s) { return }
        if ($script:Stopwatch) { $script:Stopwatch.Stop() }
        $script:Results = @($s.TopFiles(0))
        $script:Folders = @($s.TopFolders($script:Root, 400))
        Update-FilesGrid
        Update-FoldersGrid
        $secs = 0.0
        if ($script:Stopwatch) { $secs = $script:Stopwatch.Elapsed.TotalSeconds }
        $extra = ''
        if ($s.Truncated) { $extra = $script:L.Capped }
        if ($s.Error) { $extra = $extra + $script:L.ErrPrefix + $s.Error }
        $script:lblStatus.Text = ($script:L.Finished -f $s.Scanned, (Format-Size $s.TotalBytes), $secs, $s.Denied, $extra)
    }

    $script:timer.Add_Tick({
        $s = $script:Scanner
        if ($null -eq $s) { return }
        if ($s.Done) { Complete-Scan; return }
        $script:lblStatus.Text = ($script:L.Scanning -f $s.Scanned, (Format-Size $s.TotalBytes), $s.Files.Count, (Get-ShortPath $s.Current))
    })

    $script:btnScan.Add_Click({
        $p = $script:txtPath.Text.Trim().Trim('"')
        if (-not $p) {
            [void][System.Windows.Forms.MessageBox]::Show($script:L.PickPath, $script:L.WarnTitle, 'OK', 'Warning')
            return
        }
        if (-not (Test-Path -LiteralPath $p)) {
            [void][System.Windows.Forms.MessageBox]::Show(($script:L.NoPath + [Environment]::NewLine + $p), $script:L.ErrTitle, 'OK', 'Error')
            return
        }
        $script:Root = (Resolve-Path -LiteralPath $p).Path
        $script:txtPath.Text = $script:Root
        $script:dgvF.Rows.Clear()
        $script:dgvD.Rows.Clear()
        $script:Results = @()
        $script:Folders = @()
        $script:Scanner = New-Object BigFileScanner
        $script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $minBytes = [long]([double]$script:numMin.Value * 1MB)
        $script:Scanner.StartAsync($script:Root, $minBytes)
        $script:btnScan.Enabled = $false
        $script:btnStop.Enabled = $true
        $script:prog.MarqueeAnimationSpeed = 30
        $script:timer.Start()
    })

    $script:btnStop.Add_Click({
        if ($script:Scanner) { $script:Scanner.Cancel = $true }
        $script:btnStop.Enabled = $false
    })

    $btnBrowse.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $script:L.BrowseDesc
        $d.ShowNewFolderButton = $false
        if ($script:txtPath.Text -and (Test-Path -LiteralPath $script:txtPath.Text)) { $d.SelectedPath = $script:txtPath.Text }
        if ($d.ShowDialog() -eq 'OK') { $script:txtPath.Text = $d.SelectedPath }
    })

    $btnAdmin.Add_Click({
        $argline = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $PSCommandPath + '" -Lang ' + $script:UILang
        try {
            Start-Process powershell.exe -ArgumentList $argline -Verb RunAs
            $form.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($script:L.AdminFail, $script:L.ErrTitle, 'OK', 'Error')
        }
    })

    $btnLang.Add_Click({
        $newLang = 'en'
        if ($script:UILang -eq 'en') { $newLang = 'ar' }
        Save-Lang $newLang
        $argline = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $PSCommandPath + '" -Lang ' + $newLang
        $p = $script:txtPath.Text.Trim()
        if ($p) { $argline = $argline + ' -Path "' + $p + '"' }
        $argline = $argline + ' -MinSizeMB ' + ([double]$script:numMin.Value) + ' -Top ' + ([int]$script:numTop.Value)
        try {
            Start-Process powershell.exe -ArgumentList $argline
            $form.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($script:L.AdminFail, $script:L.ErrTitle, 'OK', 'Error')
        }
    })

    $btnAbout.Add_Click({
        $nl = [Environment]::NewLine
        $m = $script:L.AboutBody -f $script:APP_VERSION, $nl, $script:AUTHOR_MAIL
        [void][System.Windows.Forms.MessageBox]::Show($m, $script:L.About, 'OK', 'Information')
    })

    $script:txtFilter.Add_TextChanged({ if ($script:Results.Count) { Update-FilesGrid } })
    $script:txtExt.Add_TextChanged({ if ($script:Results.Count) { Update-FilesGrid } })
    $script:numTop.Add_ValueChanged({ if ($script:Results.Count) { Update-FilesGrid } })

    # ---------- العمليات / actions ----------
    function Get-SelectedPaths {
        $list = New-Object System.Collections.ArrayList
        if ($tabs.SelectedIndex -eq 0) {
            foreach ($r in $script:dgvF.SelectedRows) { [void]$list.Add([string]$r.Cells['colFull'].Value) }
        } else {
            foreach ($r in $script:dgvD.SelectedRows) { [void]$list.Add([string]$r.Cells['colDPath'].Value) }
        }
        return $list
    }

    function Get-SelectedBytes {
        $t = [long]0
        if ($tabs.SelectedIndex -eq 0) {
            foreach ($r in $script:dgvF.SelectedRows) { $t = $t + [long]$r.Cells['colBytes'].Value }
        } else {
            foreach ($r in $script:dgvD.SelectedRows) { $t = $t + [long]$r.Cells['colDBytes'].Value }
        }
        return $t
    }

    function Remove-FromView {
        param($paths)
        $set = @{}
        foreach ($p in $paths) { $set[$p] = $true }
        if ($tabs.SelectedIndex -eq 0) {
            $script:Results = @($script:Results | Where-Object { -not $set.ContainsKey($_.FullPath) })
            Update-FilesGrid
        } else {
            foreach ($r in @($script:dgvD.SelectedRows)) {
                if ($set.ContainsKey([string]$r.Cells['colDPath'].Value)) { $script:dgvD.Rows.Remove($r) }
            }
        }
    }

    function Invoke-DeleteSelected {
        param([bool]$Permanent)
        $L = $script:L
        $paths = Get-SelectedPaths
        if ($paths.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($L.SelectOne, $L.WarnTitle, 'OK', 'Information')
            return
        }
        $bytes = Get-SelectedBytes
        $nl = [Environment]::NewLine
        $kind = $L.KindRecyc
        $icon = 'Question'
        if ($Permanent) { $kind = $L.KindPerm; $icon = 'Warning' }
        $preview = (@($paths) | Select-Object -First 8) -join $nl
        if ($paths.Count -gt 8) { $preview = $preview + $nl + ($L.AndMore -f ($paths.Count - 8)) }
        $msg = ($L.DelHead -f $paths.Count, (Format-Size $bytes), $kind) + $nl + $nl + $preview + $nl + $nl + $L.Proceed
        if ([System.Windows.Forms.MessageBox]::Show($msg, $L.ConfTitle, 'YesNo', $icon, 'Button2') -ne 'Yes') { return }

        $recycle = 'SendToRecycleBin'
        if ($Permanent) { $recycle = 'DeletePermanently' }
        $ok = New-Object System.Collections.ArrayList
        $errs = New-Object System.Collections.ArrayList
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        foreach ($p in $paths) {
            try {
                if (Test-Path -LiteralPath $p -PathType Container) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', $recycle)
                } else {
                    try { Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { }
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', $recycle)
                }
                [void]$ok.Add($p)
            } catch {
                [void]$errs.Add($p + '  ==>  ' + $_.Exception.Message)
            }
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Remove-FromView $ok
        $rep = ($L.DelDone -f $ok.Count, (Format-Size $bytes))
        if ($errs.Count) { $rep = $rep + $nl + ($L.FailHead -f $errs.Count) + $nl + ((@($errs) | Select-Object -First 10) -join $nl) }
        [void][System.Windows.Forms.MessageBox]::Show($rep, $L.ResTitle, 'OK', 'Information')
    }

    $btnRecyc.Add_Click({ Invoke-DeleteSelected $false })
    $btnPerm.Add_Click({ Invoke-DeleteSelected $true })

    $btnMove.Add_Click({
        $L = $script:L
        $paths = Get-SelectedPaths
        if ($paths.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($L.SelectOne, $L.WarnTitle, 'OK', 'Information')
            return
        }
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $L.DestDesc
        if ($d.ShowDialog() -ne 'OK') { return }
        $dest = $d.SelectedPath
        $ok = New-Object System.Collections.ArrayList
        $errs = New-Object System.Collections.ArrayList
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        foreach ($p in $paths) {
            try {
                $target = Join-Path $dest ([System.IO.Path]::GetFileName($p))
                if (Test-Path -LiteralPath $target) {
                    $bn = [System.IO.Path]::GetFileNameWithoutExtension($p)
                    $ex = [System.IO.Path]::GetExtension($p)
                    $target = Join-Path $dest ($bn + '_' + (Get-Date -Format 'HHmmss') + $ex)
                }
                Move-Item -LiteralPath $p -Destination $target -Force -ErrorAction Stop
                [void]$ok.Add($p)
            } catch {
                [void]$errs.Add($p + '  ==>  ' + $_.Exception.Message)
            }
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Remove-FromView $ok
        $nl = [Environment]::NewLine
        $rep = ($L.MoveDone -f $ok.Count, $dest)
        if ($errs.Count) { $rep = $rep + $nl + ($L.FailHead -f $errs.Count) + $nl + ((@($errs) | Select-Object -First 10) -join $nl) }
        [void][System.Windows.Forms.MessageBox]::Show($rep, $L.ResTitle, 'OK', 'Information')
    })

    $btnOpen.Add_Click({
        $paths = Get-SelectedPaths
        if ($paths.Count -eq 0) { return }
        $p = $paths[0]
        if (Test-Path -LiteralPath $p -PathType Container) {
            Start-Process explorer.exe -ArgumentList ('"' + $p + '"')
        } else {
            Start-Process explorer.exe -ArgumentList ('/select,"' + $p + '"')
        }
    })

    $btnCopy.Add_Click({
        $paths = Get-SelectedPaths
        if ($paths.Count -eq 0) { return }
        [System.Windows.Forms.Clipboard]::SetText((@($paths) -join [Environment]::NewLine))
        $script:lblStatus.Text = ($script:L.Copied -f $paths.Count)
    })

    $btnCsv.Add_Click({
        $L = $script:L
        if ($script:Results.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($L.NoResults, $L.WarnTitle, 'OK', 'Information')
            return
        }
        $sd = New-Object System.Windows.Forms.SaveFileDialog
        $sd.Filter = 'CSV (*.csv)|*.csv'
        $sd.FileName = 'big-files-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.csv'
        if ($sd.ShowDialog() -ne 'OK') { return }
        $rows = foreach ($it in $script:Results) {
            [PSCustomObject]@{
                Size      = (Format-Size $it.SizeBytes)
                Bytes     = $it.SizeBytes
                Modified  = $it.Modified
                Extension = $it.Ext
                Name      = $it.Name
                Folder    = $it.Folder
                FullPath  = $it.FullPath
            }
        }
        $rows | Export-Csv -LiteralPath $sd.FileName -NoTypeInformation -Encoding UTF8
        $script:lblStatus.Text = ($L.ExportedTo + $sd.FileName)
    })

    $script:dgvF.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $p = [string]$s.Rows[$e.RowIndex].Cells['colFull'].Value
        if ($p) { Start-Process explorer.exe -ArgumentList ('/select,"' + $p + '"') }
    })

    $script:dgvD.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $p = [string]$s.Rows[$e.RowIndex].Cells['colDPath'].Value
        if ($p) { $script:txtPath.Text = $p }
    })

    $script:dgvF.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Delete') { Invoke-DeleteSelected ([bool]$e.Shift) }
    })

    $form.Add_FormClosing({
        if ($script:Scanner) { $script:Scanner.Cancel = $true }
        $script:timer.Stop()
    })

    if ($Path) { $script:txtPath.Text = $Path }
    elseif (-not $script:txtPath.Text) { $script:txtPath.Text = (Get-Location).Path }

    if ($BuildOnly) { $form.Dispose(); return 'UI-OK' }

    if ($Shot) {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            $script:Root = (Resolve-Path -LiteralPath $Path).Path
            $script:Scanner = New-Object BigFileScanner
            $script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $script:Scanner.Scan($script:Root, [long]([double]$script:numMin.Value * 1MB))
            Complete-Scan
        }
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
        $form.Dispose()
        return 'SHOT-OK'
    }

    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $true
        $form.TopMost = $false
        if ($script:AutoStart) { $script:btnScan.PerformClick() }
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}

# ==================================================================
#  نقطة الدخول / entry point
# ==================================================================
if ($SelfTest) {
    $r = Show-BigFileFinder -BuildOnly
    Write-Host ('SelfTest: ' + $r + ' (lang=' + $script:UILang + ')') -ForegroundColor Green
    return
}

if ($Shot) {
    $r = Show-BigFileFinder
    Write-Host ('Shot: ' + $r + ' -> ' + $Shot) -ForegroundColor Green
    return
}

if ($NoGui) {
    if (-not $Path) { throw $script:L.CNoPath }
    Invoke-ConsoleScan -Root $Path -MinMB $MinSizeMB -TopN $Top -CsvOut $Csv
    return
}

Show-BigFileFinder
