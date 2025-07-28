#./Internalize-Package.ps1

param(
    [Parameter(Mandatory = $true)]
    [string]$PackageName,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

# --- 配置 ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$workingDir = Join-Path $env:TEMP "ChocoInternalize"
$packageDir = Join-Path $workingDir $PackageName

# --- 函数定义 ---

# 解析 PowerShell 脚本中的参数值 (处理字符串和变量)
function Get-ScriptParamValue {
    param($scriptContent, $paramName)
    # 匹配 $variable = 'value' 或 $variable = "value"
    $regex = "(?i)\$${paramName}\s*=\s*['""]([^'""]+)['""]"
    $match = $scriptContent | Select-String -Pattern $regex
    if ($match) { return $match.Matches.Groups.[1]Value }

    # 匹配 -parameter 'value' 或 -parameter "value"
    $regex = "(?i)-${paramName}\s+['""]?([^'""]+)['""]?"
    $match = $scriptContent | Select-String -Pattern $regex
    if ($match) { return $match.Matches.Groups.[1]Value }
    
    return $null
}

# --- 脚本执行 ---

try {
    # 1. 清理并创建工作目录
    if (Test-Path $packageDir) { Remove-Item -Recurse -Force $packageDir }
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

    Write-Host "--- Starting internalization for '$PackageName' ---"

    # 2. 下载原始.nupkg 包
    Write-Host "Step 1: Downloading original package for '$PackageName'..."
    $nupkgUrl = "https://community.chocolatey.org/api/v2/package/$PackageName"
    $nupkgFile = Join-Path $packageDir "$($PackageName).nupkg"
    Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgFile

    # 3. 解压.nupkg 包
    Write-Host "Step 2: Unpacking package..."
    $unpackedDir = Join-Path $packageDir "unpacked"
    Expand-Archive -Path $nupkgFile -DestinationPath $unpackedDir -Force
    $toolsDir = Join-Path $unpackedDir "tools"
    $installScriptPath = Join-Path $toolsDir "chocolateyInstall.ps1"

    if (-not (Test-Path $installScriptPath)) {
        Write-Warning "No chocolateyInstall.ps1 found. Assuming package is already self-contained."
        Copy-Item -Path $nupkgFile -Destination $OutputDirectory
        return
    }

    # 4. 解析安装脚本，查找并下载外部资源
    Write-Host "Step 3: Parsing install script and downloading resources..."
    $scriptContent = Get-Content $installScriptPath -Raw
    
    # 查找 URL 和 URL64
    $url = Get-ScriptParamValue -scriptContent $scriptContent -paramName "url"
    $url64 = Get-ScriptParamValue -scriptContent $scriptContent -paramName "url64"

    $resources = @{}
    if ($url) { $resources.Add('url', $url) }
    if ($url64) { $resources.Add('url64', $url64) }

    if ($resources.Count -eq 0) {
        Write-Warning "No external URLs found in script. Assuming package is already self-contained."
        Copy-Item -Path $nupkgFile -Destination $OutputDirectory
        return
    }

    foreach ($key in $resources.Keys) {
        $resourceUrl = $resources[$key]
        $fileName =::GetFileName($resourceUrl.Split('?'))
        $localFilePath = Join-Path $toolsDir $fileName
        
        Write-Host "Downloading resource for '$key': $resourceUrl"
        Invoke-WebRequest -Uri $resourceUrl -OutFile $localFilePath
        $resources[$key] = $fileName # 更新值为本地文件名
    }

    # 5. 修改安装脚本
    Write-Host "Step 4: Modifying install script to use local resources..."
    $newScriptContent = $scriptContent
    
    # 移除 URL 和 Checksum 参数
    $newScriptContent = $newScriptContent -replace "(?i)(-|`\s)\$url\s*=\s*['""].+?['""]", ""
    $newScriptContent = $newScriptContent -replace "(?i)(-|`\s)\$url64\s*=\s*['""].+?['""]", ""
    $newScriptContent = $newScriptContent -replace "(?i)(-|`\s)-(url|url64|checksum|checksum64|checksumtype)\s+['""].+?['""]", ""
    
    # 这是一个通用的替换方法，直接修改 Install-ChocolateyPackage
    if ($resources.ContainsKey('url')) {
         $newScriptContent = $newScriptContent -replace "(Install-ChocolateyPackage)", ('$1' + " -File `"$toolsDir\$($resources['url'])`"")
    }
    if ($resources.ContainsKey('url64')) {
         $newScriptContent = $newScriptContent -replace "(Install-ChocolateyPackage)", ('$1' + " -File64 `"$toolsDir\$($resources['url64'])`"")
    }
    
    # 将 Install-ChocolateyPackage 替换为更合适的 Install-ChocolateyInstallPackage
    $newScriptContent = $newScriptContent -replace "Install-ChocolateyPackage", "Install-ChocolateyInstallPackage"
    $newScriptContent = $newScriptContent -replace "Install-ChocolateyZipPackage", "Install-ChocolateyInstallPackage"

    Set-Content -Path $installScriptPath -Value $newScriptContent

    # 6. 重新打包
    Write-Host "Step 5: Repacking the internalized package..."
    # 删除打包时会引起冲突的元数据文件
    Get-ChildItem -Path $unpackedDir -Directory -Filter "_rels" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $unpackedDir -Directory -Filter "package" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $unpackedDir -File -Filter "*.xml" | Remove-Item -Force -ErrorAction SilentlyContinue

    choco pack (Join-Path $unpackedDir "*.nuspec") --output-directory $OutputDirectory

    Write-Host "--- Successfully internalized '$PackageName' ---" -ForegroundColor Green

}
catch {
    Write-Error "Failed to internalize package '$PackageName'. Error: $_"
    exit 1
}
finally {
    # 7. 清理工作目录
    if (Test-Path $workingDir) { Remove-Item -Recurse -Force $workingDir }
}
