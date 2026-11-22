<#
.SYNOPSIS
  Minimal PXE server: DHCP (UDP 67), TFTP (UDP 69) and HTTP (TCP 80).
.DESCRIPTION
  Binds only to -ServerIP, so it never answers on other networks.
  Run by Start-PxeInstall.ps1. Stops on Ctrl+C, a stop.flag file, or -AutoStop.
  Editing this file makes it restart with the new code (restart.flag tells the caller).
#>
param(
    [Parameter(Mandatory)] [string]   $ServerIP,
    [Parameter(Mandatory)] [string]   $TftpRoot,
    [Parameter(Mandatory)] [hashtable]$HttpFiles,
    [hashtable]$Leases = [hashtable]::Synchronized(@{}),   # MAC -> IP
    [hashtable]$Done   = [hashtable]::Synchronized(@{}),   # MAC -> booted (boot.wim fully sent)
    [int]   $PoolStart = 100,
    [string]$LogFile,
    [string]$SharePath,   # -AutoStop: stop once Setup stops reading files from here
    [switch]$AutoStop
)

$S = [hashtable]::Synchronized(@{
    ServerIP  = $ServerIP
    TftpRoot  = $TftpRoot
    HttpFiles = $HttpFiles
    PoolStart = $PoolStart
    Leases    = $Leases
    Done      = $Done
    Log       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Closers   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})

# ---------------------------------------------------------------- DHCP
$dhcp = {
    param($S)
    function Log($m) { $S.Log.Enqueue("[DHCP] $m") }
    try {
        $srv = [Net.IPAddress]::Parse($S.ServerIP)
        $srvB = $srv.GetAddressBytes()
        $u = New-Object Net.Sockets.UdpClient
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $u.Client.Bind((New-Object Net.IPEndPoint($srv, 67)))
        $u.EnableBroadcast = $true
        [void]$S.Closers.Add($u)
        Log "listening on $($S.ServerIP):67"
        $bcast = New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 68)

        while ($true) {
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $p = $u.Receive([ref]$ep)
            if ($p.Length -lt 240 -or $p[0] -ne 1) { continue }
            if ($p[236] -ne 99 -or $p[237] -ne 130 -or $p[238] -ne 83 -or $p[239] -ne 99) { continue }
            if (($p[24] -bor $p[25] -bor $p[26] -bor $p[27]) -ne 0) { continue }   # relayed: not ours

            $opts = @{}; $i = 240
            while ($i -lt $p.Length) {
                $c = $p[$i]
                if ($c -eq 255) { break }
                if ($c -eq 0) { $i++; continue }
                $l = $p[$i + 1]
                if ($l -gt 0) { $opts[[int]$c] = [byte[]]@($p[($i + 2)..($i + 1 + $l)]) } else { $opts[[int]$c] = [byte[]]@() }
                $i += 2 + $l
            }
            if (-not $opts.ContainsKey(53)) { continue }
            $type = $opts[53][0]
            if ($type -ne 1 -and $type -ne 3) { continue }   # only DISCOVER / REQUEST

            $mac    = (@($p[28..33]) | ForEach-Object { $_.ToString('X2') }) -join ':'
            $vendor = if ($opts[60]) { [Text.Encoding]::ASCII.GetString($opts[60]) } else { '' }
            $uclass = if ($opts[77]) { [Text.Encoding]::ASCII.GetString($opts[77]) } else { '' }
            $isIpxe = $uclass -match 'iPXE'
            $isPxe  = $vendor -like 'PXEClient*'
            $arch   = if ($opts[93] -and $opts[93].Length -ge 2) { [int]$opts[93][0] * 256 + [int]$opts[93][1] } else { -1 }

            if ($type -eq 3 -and $opts[54]) {
                if ([Net.IPAddress]::new($opts[54]).ToString() -ne $S.ServerIP) { continue }  # chose another server
            }
            if (($isPxe -or $isIpxe) -and $S.Done.ContainsKey($mac)) {
                if ($type -eq 1) { Log "$mac already installed this run - ignoring network boot so it starts from its disk" }
                continue
            }

            if (-not $S.Leases.ContainsKey($mac)) {
                $pre = (($S.ServerIP -split '\.')[0..2]) -join '.'
                $S.Leases[$mac] = "$pre.$($S.PoolStart + $S.Leases.Count)"
            }
            $ip = [Net.IPAddress]::Parse($S.Leases[$mac])

            $file = ''
            if ($isIpxe) { $file = "http://$($S.ServerIP)/boot.ipxe" }
            elseif ($isPxe) { $file = if ($arch -eq 0) { 'ipxe.pxe' } else { 'ipxe.efi' } }   # arch 0 = BIOS

            $r = New-Object byte[] 548
            $r[0] = 2; $r[1] = 1; $r[2] = 6
            [Array]::Copy($p, 4, $r, 4, 4)            # xid
            [Array]::Copy($p, 10, $r, 10, 2)          # flags
            [Array]::Copy($ip.GetAddressBytes(), 0, $r, 16, 4)   # yiaddr
            [Array]::Copy($srvB, 0, $r, 20, 4)        # siaddr (TFTP server)
            [Array]::Copy($p, 28, $r, 28, 16)         # chaddr
            if ($file) {
                $fb = [Text.Encoding]::ASCII.GetBytes($file)
                [Array]::Copy($fb, 0, $r, 108, [Math]::Min($fb.Length, 127))
            }
            $r[236] = 99; $r[237] = 130; $r[238] = 83; $r[239] = 99
            $ol = New-Object System.Collections.Generic.List[byte]
            $add = { param([int]$code, [byte[]]$val) $ol.Add([byte]$code); $ol.Add([byte]$val.Length); $ol.AddRange($val) }
            $reply = if ($type -eq 1) { 2 } else { 5 }
            & $add 53 ([byte[]]@($reply))
            & $add 54 $srvB
            & $add 51 ([byte[]]@(0, 1, 81, 128))     # 86400 s
            & $add 1  ([byte[]]@(255, 255, 255, 0))
            if ($isPxe) {
                & $add 60 ([Text.Encoding]::ASCII.GetBytes('PXEClient'))
                if (-not $isIpxe) { & $add 43 ([byte[]]@(6, 1, 8, 255)) }   # PXE: use boot file directly
                if ($opts[97]) { & $add 97 $opts[97] }                      # echo client UUID; some ROMs require it
            }
            if ($file) {
                & $add 66 ([Text.Encoding]::ASCII.GetBytes($S.ServerIP))
                & $add 67 ([Text.Encoding]::ASCII.GetBytes($file))
            }
            $ol.Add(255)
            $ob = $ol.ToArray()
            [Array]::Copy($ob, 0, $r, 240, $ob.Length)
            $len = [Math]::Max(300, 240 + $ob.Length)
            [void]$u.Send($r, $len, $bcast)

            $kind = if ($isIpxe) { 'iPXE' } elseif ($isPxe) { "PXE arch=$arch" } else { $vendor }
            $what = if ($reply -eq 2) { 'OFFER' } else { 'ACK' }
            Log "$what $ip -> $mac ($kind)$(if ($file) { " file=$file" })"
        }
    } catch { Log "STOPPED: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- TFTP
$tftp = {
    param($S)
    function Log($m) { $S.Log.Enqueue("[TFTP] $m") }
    function U16([int]$v) { [byte[]]@((($v -shr 8) -band 255), ($v -band 255)) }
    try {
        $srv = [Net.IPAddress]::Parse($S.ServerIP)
        $u = New-Object Net.Sockets.UdpClient((New-Object Net.IPEndPoint($srv, 69)))
        [void]$S.Closers.Add($u)
        Log "listening on $($S.ServerIP):69"
        while ($true) {
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $p = $u.Receive([ref]$ep)
            if ($p.Length -lt 4 -or ($p[0] * 256 + $p[1]) -ne 1) { continue }   # RRQ only
            $parts = [Text.Encoding]::ASCII.GetString($p, 2, $p.Length - 2).Split([char]0)
            $name  = [IO.Path]::GetFileName($parts[0].Replace('\', '/'))
            $req = @{}
            for ($k = 2; $k + 1 -lt $parts.Length; $k += 2) { if ($parts[$k]) { $req[$parts[$k].ToLower()] = $parts[$k + 1] } }

            $t = New-Object Net.Sockets.UdpClient((New-Object Net.IPEndPoint($srv, 0)))
            $t.Client.ReceiveTimeout = 1500
            $t.Connect($ep)
            try {
                $path = Join-Path $S.TftpRoot $name
                if (-not $name -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $e = [byte[]](@(0, 5, 0, 1) + [Text.Encoding]::ASCII.GetBytes('File not found') + @(0))
                    [void]$t.Send($e, $e.Length); Log "$($ep.Address) asked for '$name' - not found"; continue
                }
                $data = [IO.File]::ReadAllBytes($path)
                $blk = 512
                $oack = New-Object System.Collections.Generic.List[byte]
                if ($req.ContainsKey('blksize')) {
                    $blk = [Math]::Max(8, [Math]::Min([int]$req['blksize'], 1456))
                    $oack.AddRange([Text.Encoding]::ASCII.GetBytes("blksize`0$blk`0"))
                }
                if ($req.ContainsKey('tsize')) { $oack.AddRange([Text.Encoding]::ASCII.GetBytes("tsize`0$($data.Length)`0")) }

                $wait = {   # send $pkt until ACK for block $want arrives
                    param([byte[]]$pkt, [int]$want)
                    for ($try = 0; $try -lt 6; $try++) {
                        [void]$t.Send($pkt, $pkt.Length)
                        try {
                            while ($true) {
                                $rep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                                $a = $t.Receive([ref]$rep)
                                $op = $a[0] * 256 + $a[1]
                                if ($op -eq 5) { return 'error' }
                                if ($op -eq 4 -and ($a[2] * 256 + $a[3]) -eq $want) { return 'ok' }
                            }
                        } catch [Net.Sockets.SocketException] { }
                    }
                    'timeout'
                }

                if ($oack.Count -gt 0) {
                    $res = & $wait ([byte[]](@(0, 6) + $oack.ToArray())) 0
                    if ($res -ne 'ok') { Log "$($ep.Address) $name : client stopped after options ($res)"; continue }
                }
                $n = 1; $off = 0; $res = 'ok'
                while ($true) {
                    $len = [Math]::Min($blk, $data.Length - $off)
                    $pkt = New-Object byte[] (4 + $len)
                    $pkt[1] = 3; $b = U16 ($n -band 0xFFFF); $pkt[2] = $b[0]; $pkt[3] = $b[1]
                    if ($len -gt 0) { [Array]::Copy($data, $off, $pkt, 4, $len) }
                    $res = & $wait $pkt ($n -band 0xFFFF)
                    if ($res -ne 'ok') { break }
                    $off += $len; $n++
                    if ($len -lt $blk) { break }
                }
                if ($res -eq 'ok') { Log "sent $name ($($data.Length) bytes) to $($ep.Address)" }
                else { Log "$name to $($ep.Address) aborted ($res)" }
            } finally { $t.Close() }
        }
    } catch { Log "STOPPED: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- HTTP
$http = {
    param($S)
    function Log($m) { $S.Log.Enqueue("[HTTP] $m") }
    try {
        $l = New-Object Net.HttpListener
        $l.Prefixes.Add("http://$($S.ServerIP):80/")
        $l.Start()
        [void]$S.Closers.Add($l)
        Log "listening on http://$($S.ServerIP)/"
        # one thread per request, so a stalled download can't block a retry
        $pool = [runspacefactory]::CreateRunspacePool(1, 8); $pool.Open()
        $serve = {
            param($ctx, $S)
            function Log($m) { $S.Log.Enqueue("[HTTP] $m") }
            $name = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
            $client = $ctx.Request.RemoteEndPoint.Address.ToString()
            $res = $ctx.Response
            try {
                $file = $S.HttpFiles[$name]
                if (-not $file -or -not (Test-Path -LiteralPath $file)) {
                    $res.StatusCode = 404; Log "$client asked for '$name' - not found"; return
                }
                $fs = [IO.File]::OpenRead($file)
                try {
                    $res.ContentType = 'application/octet-stream'
                    $res.ContentLength64 = $fs.Length
                    $big = $fs.Length -gt 50MB
                    if ($big) { Log "sending $name ($([Math]::Round($fs.Length / 1MB)) MB) to $client ..." }
                    $buf = New-Object byte[] 262144; $sent = 0; $nextMark = 100MB
                    $out = $res.OutputStream
                    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                        if (-not $out.WriteAsync($buf, 0, $n).Wait(30000)) {
                            throw "stalled: client accepted no data for 30 s at $([Math]::Round($sent / 1MB)) MB"
                        }
                        $sent += $n
                        if ($big -and $sent -ge $nextMark) { Log "  $name $([Math]::Round($sent / 1MB)) MB sent"; $nextMark += 100MB }
                    }
                } finally { $fs.Close() }
                Log "sent $name ($([Math]::Round($sent / 1MB, 1)) MB) to $client"
                if ($name -eq 'boot.wim') {
                    foreach ($k in @($S.Leases.Keys)) { if ($S.Leases[$k] -eq $client) { $S.Done[$k] = $true } }
                }
                $res.Close()
            } catch {
                Log "$client $name failed: $($_.Exception.Message)"
                try { $res.Abort() } catch { }
            }
        }
        while ($true) {
            $ctx = $l.GetContext()
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($serve).AddArgument($ctx).AddArgument($S)
            [void]$ps.BeginInvoke()
        }
    } catch { Log "STOPPED: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- run
$workers = foreach ($b in $dhcp, $tftp, $http) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($b).AddArgument($S)
    [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}

Write-Host ""
Write-Host "PXE server running on $ServerIP. Network-boot the target PC now." -ForegroundColor Green
Write-Host ""
function Out-Log($m, $color = 'Gray') {
    $line = "{0:HH:mm:ss} {1}" -f (Get-Date), $m
    Write-Host $line -ForegroundColor $color
    if ($LogFile) { for ($i = 0; $i -lt 5; $i++) { try { [IO.File]::AppendAllText($LogFile, "$line`r`n"); break } catch { Start-Sleep -Milliseconds 50 } } }
}
Out-Log "server started on $ServerIP (auto-stop: $([bool]$AutoStop))"
$sawOpen = $false; $idleSince = $null; $nextCheck = Get-Date
$self = $MyInvocation.MyCommand.Path; $selfTime = (Get-Item $self).LastWriteTime
$dir = Split-Path $self
try {
    while ($true) {
        $m = $null
        while ($S.Log.TryDequeue([ref]$m)) {
            Out-Log $m $(if ($m -match 'STOPPED|failed|not found|aborted') { 'Yellow' } else { 'Gray' })
        }
        # Auto-stop: after boot.wim is sent, wait for Setup to read from the share, then 3 idle minutes.
        if ($AutoStop -and $S.Done.Count -gt 0 -and (Get-Date) -ge $nextCheck) {
            $nextCheck = (Get-Date).AddSeconds(20)
            $open = @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$SharePath*" })
            if ($open.Count) {
                if (-not $sawOpen) { Out-Log "[AUTO] Setup is reading from the share" 'Green' }
                $sawOpen = $true; $idleSince = $null
            } elseif ($sawOpen) {
                if (-not $idleSince) { $idleSince = Get-Date; Out-Log "[AUTO] share idle - stopping in 3 minutes" }
                elseif (((Get-Date) - $idleSince).TotalMinutes -ge 3) { Out-Log "[AUTO] install files copied - stopping" 'Green'; break }
            }
        }
        $stopFlag = Join-Path $dir 'stop.flag'
        if (Test-Path $stopFlag) { Remove-Item $stopFlag -ErrorAction SilentlyContinue; Out-Log "[AUTO] stop requested" 'Green'; break }
        if ((Get-Item $self).LastWriteTime -ne $selfTime) {
            Start-Sleep 2
            Out-Log "[AUTO] script changed - restarting" 'Cyan'
            Set-Content (Join-Path $dir 'restart.flag') 'restart'; break
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host "Stopping server..."
    foreach ($c in @($S.Closers)) { try { if ($c -is [Net.HttpListener]) { $c.Stop() } else { $c.Close() } } catch { } }
    foreach ($w in $workers) { try { $w.PS.Stop() } catch { }; $w.PS.Dispose() }
}
