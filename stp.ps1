#Requires -Version 5.1

<#
.SYNOPSIS
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.DESCRIPTION
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.PARAMETER noEnvModification
Switch to omit changes of your environment i.e. just customization of cloned folders content 'repo_content_set_up' will be made.

.PARAMETER iniFile
Path to text ini file that this script uses as storage for values the user entered during this scripts run.
So next time, they can be used to speed up whole installation process.

Default is "Powershell_CICD_repository.ini" in root of user profile, so it can't be replaced when user reset cloned repository etc.

.NOTES
Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

[CmdletBinding()]
param (
    [switch] $noEnvModification
    ,
    [string] $iniFile = (Join-Path $env:USERPROFILE "Powershell_CICD_repository.ini")
)

$transcript = Join-Path $env:USERPROFILE ((Split-Path $PSCommandPath -Leaf) + ".log")
Start-Transcript $transcript -Force

$ErrorActionPreference = "Stop"

# char that is between name of variable and its value in ini file
$divider = "="
# list of variables needed for installation, will be saved to iniFile 
$setupVariable = @{}
# name of GPO that will be used for connecting computers to this solution
$GPOname = 'PS_env_set_up'

if ((Get-WmiObject -Class Win32_OperatingSystem).ProductType -in (2, 3)) {
    ++$isServer
}

#region helper functions
function _pressKeyToContinue {
    Write-Host "`nPress any key to continue" -NoNewline
    $null = [Console]::ReadKey('?')
}

function _continue {
    param ($text, [switch] $passthru)

    $t = "Continue? (Y|N)"
    if ($text) {
        $t = "$text. $t"
    }

    $choice = ""
    while ($choice -notmatch "^[Y|N]$") {
        $choice = Read-Host $t
    }
    if ($choice -eq "N") {
        if ($passthru) {
            return $choice
        }
        else {
            break
        }
    }

    if ($passthru) {
        return $choice
    }
}

function _skip {
    param ($text)

    $t = "Skip? (Y|N)"
    if ($text) {
        $t = "$text. $t"
    }
    $t = "`n$t"

    $choice = ""
    while ($choice -notmatch "^[Y|N]$") {
        $choice = Read-Host $t
    }
    if ($choice -eq "N") {
        return $false
    }
    else {
        return $true
    }
}

function _getComputerMembership {
    # Pull the gpresult for the current server
    $Lines = gpresult /s $env:COMPUTERNAME /v /SCOPE COMPUTER
    # Initialize arrays
    $cgroups = @()
    # Out equals false by default
    $Out = $False
    # Define start and end lines for the section we want
    $start = "The computer is a part of the following security groups"
    $end = "Resultant Set Of Policies for Computer"
    # Loop through the gpresult output looking for the computer security group section
    ForEach ($Line In $Lines) {
        If ($Line -match $start) { $Out = $True }
        If ($Out -eq $True) { $cgroups += $Line }
        If ($Line -match $end) { Break }
    }
    $cgroups | % { $_.trim() }
}

function _startProcess {
    [CmdletBinding()]
    param (
        [string] $filePath = ''
        ,
        [string] $argumentList = ''
        ,
        [string] $workingDirectory = (Get-Location)
        ,
        [switch] $dontWait
        ,
        # lot of git commands output verbose output to error stream
        [switch] $outputErr2Std
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $workingDirectory
    $p.StartInfo.FileName = $filePath
    $p.StartInfo.Arguments = $argumentList
    [void]$p.Start()
    if (!$dontWait) {
        $p.WaitForExit()
    }
    $p.StandardOutput.ReadToEnd()
    if ($outputErr2Std) {
        $p.StandardError.ReadToEnd()
    }
    else {
        if ($err = $p.StandardError.ReadToEnd()) {
            Write-Error $err
        }
    }
}

function _setVariable {
    # function defines variable and fills it with value find in ini file or entered by user
    param ([string] $variable, [string] $readHost, [switch] $optional, [switch] $passThru)

    $value = $setupVariable.GetEnumerator() | ? { $_.name -eq $variable -and $_.value } | select -exp value
    if (!$value) {
        if ($optional) {
            $value = Read-Host "    - (OPTIONAL) Enter $readHost"
        }
        else {
            while (!$value) {
                $value = Read-Host "    - Enter $readHost"
            }
        }
    }
    else {
        # Write-Host "   - variable '$variable' will be: $value" -ForegroundColor Gray
    }
    if ($value) {
        # replace whitespaces so as quotes
        $value = $value -replace "^\s*|\s*$" -replace "^[`"']*|[`"']*$"
        $setupVariable.$variable = $value
        New-Variable $variable $value -Scope script -Force -Confirm:$false
    }
    else {
        if (!$optional) {
            throw "Variable $variable is mandatory!"
        }
    }

    if ($passThru) {
        return $value
    }
}

function _saveInput {
    # call after each successfuly ended section, so just correct inputs will be stored
    if (Test-Path $iniFile -ea SilentlyContinue) {
        Remove-Item $iniFile -Force -Confirm:$false
    }
    $setupVariable.GetEnumerator() | % {
        if ($_.name -and $_.value) {
            $_.name + "=" + $_.value | Out-File $iniFile -Append -Encoding utf8
        }
    }
}

function _setPermissions {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $path
        ,
        $readUser
        ,
        $writeUser
        ,
        [switch] $resetACL
    )

    if (!(Test-Path $path)) {
        throw "Path isn't accessible"
    }

    $permissions = @()

    if (Test-Path $path -PathType Container) {
        # it is folder
        $acl = New-Object System.Security.AccessControl.DirectorySecurity

        if ($resetACL) {
            # reset ACL, i.e. remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        }
        else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            if ($readUser) {
                $readUser | ForEach-Object {
                    $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
            }
            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
            }
        }
    }
    else {
        # it is file

        $acl = New-Object System.Security.AccessControl.FileSecurity
        if ($resetACL) {
            # reset ACL, ie remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        }
        else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            if ($readUser) {
                $readUser | ForEach-Object {
                    $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
                }
            }

            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'Allow'))
                }
            }
        }
    }

    $permissions | ForEach-Object {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        $acl.AddAccessRule($ace)
    }

    try {
        # Set-Acl cannot be used because of bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    }
    catch {
        throw "There was an error when setting NTFS rights: $_"
    }
}

function _copyFolder {
    [cmdletbinding()]
    Param (
        [string] $source
        ,
        [string] $destination
        ,
        [string] $excludeFolder = ""
        ,
        [switch] $mirror
    )

    Process {
        if ($mirror) {
            $result = Robocopy.exe "$source" "$destination" /MIR /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        }
        else {
            $result = Robocopy.exe "$source" "$destination" /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        }

        $copied = 0
        $failures = 0
        $duration = ""
        $deleted = @()
        $errMsg = @()

        $result | ForEach-Object {
            if ($_ -match "\s+Dirs\s+:") {
                $lineAsArray = (($_.Split(':')[1]).trim()) -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Files\s+:") {
                $lineAsArray = ($_.Split(':')[1]).trim() -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Times\s+:") {
                $lineAsArray = ($_.Split(':', 2)[1]).trim() -split '\s+'
                $duration = $lineAsArray[0]
            }
            if ($_ -match "\*EXTRA \w+") {
                $deleted += @($_ | ForEach-Object { ($_ -split "\s+")[-1] })
            }
            if ($_ -match "^ERROR: ") {
                $errMsg += ($_ -replace "^ERROR:\s+")
            }
            # captures errors like: 2020/04/27 09:01:27 ERROR 2 (0x00000002) Accessing Source Directory C:\temp
            if ($match = ([regex]"^[0-9 /]+ [0-9:]+ ERROR \d+ \([0-9x]+\) (.+)").Match($_).captures.groups) {
                $errMsg += $match[1].value
            }
        }

        return [PSCustomObject]@{
            'Copied'   = $copied
            'Failures' = $failures
            'Duration' = $duration
            'Deleted'  = $deleted
            'ErrMsg'   = $errMsg
        }
    }
}

function _installGIT {
    $installedGITVersion = ( (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*) + (Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*) | ? { $_.DisplayName -and $_.Displayname.Contains('Git version') }) | select -exp DisplayVersion

    if (!$installedGITVersion -or $installedGITVersion -as [version] -lt "2.27.0") {
        # get latest download url for git-for-windows 64-bit exe
        $url = "https://api.github.com/repos/git-for-windows/git/releases/latest"
        if ($asset = Invoke-RestMethod -Method Get -Uri $url | % { $_.assets } | ? { $_.name -like "*64-bit.exe" }) {
            "      - downloading"
            $installer = "$env:temp\$($asset.name)"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer
            "      - installing"
            $install_args = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
            Start-Process -FilePath $installer -ArgumentList $install_args -Wait
        }
        else {
            Write-Warning "Skipped!`nURL $url isn't accessible, install GIT manually"

            _continue
        }
    }
    else {
        "      - already installed"
    }
}

function _installGITCredManager {
    $ErrorActionPreference = "Stop"
    $url = "https://github.com/Microsoft/Git-Credential-Manager-for-Windows/releases/latest"
    $asset = Invoke-WebRequest $url -UseBasicParsing
    try {
        $durl = (($asset.RawContent -split "`n" | ? { $_ -match '<a href="/.+\.exe"' }) -split '"')[1]
    }
    catch {}
    if ($durl) {
        $url = "github.com" + $durl
        $installer = "$env:temp\gitcredmanager.exe"
        "      - downloading"
        Invoke-WebRequest -Uri $url -OutFile $installer
        "      - installing"
        $install_args = "/VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
        Start-Process -FilePath $installer -ArgumentList $install_args -Wait
    }
    else {
        Write-Warning "Skipped!`nURL $url isn't accessible, install GIT Credential Manager for Windows manually"
    
        _continue
    }
}

function _createSchedTask {
    param ($xmlDefinition, $taskName)
    $result = schtasks /CREATE /XML "$xmlDefinition" /TN "$taskName" /F

    if (!$?) {
        throw "Unable to create scheduled task $taskName"
    }
}

function _startSchedTask {
    param ($taskName)
    $result = schtasks /RUN /I /TN "$taskName"

    if (!$?) {
        throw "Task $taskName finished with error. Check '$env:SystemRoot\temp\repo_sync.ps1.log'"
    }
}

function _exportCred {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $credential
        ,
        [string] $xmlPath = "C:\temp\login.xml"
        ,
        [Parameter(Mandatory = $true)]
        [string] $runAs
    )

    begin {
        # transform relative path to absolute
        try {
            $null = Split-Path $xmlPath -Qualifier -ea Stop
        }
        catch {
            $xmlPath = Join-Path (Get-Location) $xmlPath
        }

        # remove existing xml
        Remove-Item $xmlPath -ea SilentlyContinue -Force

        # create destination folder
        [Void][System.IO.Directory]::CreateDirectory((Split-Path $xmlPath -Parent))
    }

    process {
        $login = $credential.UserName
        $pswd = $credential.GetNetworkCredential().password

        $command = @"
            # just in case auto-load of modules would be broken
            import-module `$env:windir\System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security -ea Stop
            `$pswd = ConvertTo-SecureString `'$pswd`' -AsPlainText -Force
            `$credential = New-Object System.Management.Automation.PSCredential $login, `$pswd
            Export-Clixml -inputObject `$credential -Path $xmlPath -Encoding UTF8 -Force -ea Stop
"@

        # encode as base64
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
        $encodedString = [Convert]::ToBase64String($bytes)
        #TODO idealne pomoci schtasks aby bylo univerzalnejsi
        $A = New-ScheduledTaskAction -Argument "-executionpolicy bypass -noprofile -encodedcommand $encodedString" -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        if ($runAs -match "\$") {
            # under gMSA account
            $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType Password
        }
        else {
            # under system account
            $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType ServiceAccount
        }
        $S = New-ScheduledTaskSettingsSet
        $taskName = "cred_export"
        try {
            $null = New-ScheduledTask -Action $A -Principal $P -Settings $S -ea Stop | Register-ScheduledTask -Force -TaskName $taskName -ea Stop
        }
        catch {
            if ($_ -match "No mapping between account names and security IDs was done") {
                throw "Account $runAs doesn't exist or cannot be used on $env:COMPUTERNAME"
            }
            else {
                throw "Unable to create scheduled task for exporting credentials.`nError was:`n$_"
            }
        }

        Start-Sleep -Seconds 1
        Start-ScheduledTask $taskName

        Start-Sleep -Seconds 5
        $result = (Get-ScheduledTaskInfo $taskName).LastTaskResult
        try {
            Unregister-ScheduledTask $taskName -Confirm:$false -ea Stop
        }
        catch {
            throw "Unable to remove scheduled task $taskName. Remove it manually, it contains the credentials!"
        }

        if ($result -ne 0) {
            throw "Export of the credentials end with error"
        }

        if ((Get-Item $xmlPath).Length -lt 500) {
            # sometimes sched. task doesn't end with error, but xml contained gibberish
            throw "Exported credentials are not valid"
        }
    }
}
#endregion helper functions

# store function definitions so I can recreate them in scriptblock
$allFunctionDefs = "function _continue { ${function:_continue} };function _pressKeyToContinue { ${function:_pressKeyToContinue} }; function _skip { ${function:_skip} }; function _installGIT { ${function:_installGIT} }; function _installGITCredManager { ${function:_installGITCredManager} }; function _createSchedTask { ${function:_createSchedTask} }; function _exportCred { ${function:_exportCred} }; function _startSchedTask { ${function:_startSchedTask} }; function _setPermissions { ${function:_setPermissions} }; function _getComputerMembership { ${function:_getComputerMembership} }; function _startProcess { ${function:_startProcess} }"

#region initial
if (!$noEnvModification) {
    Clear-Host
    @"
####################################
#   INSTALL OPTIONS
####################################

1) Initial installation
    - this script will set up your own GIT repository so as your environment by:
        - creating repo_reader, repo_writer AD groups
        - create shared folder for serving repository data to clients
        - customize generic data from repo_content_set_up folder to match your environment
        - copy customized data to your repository
        - set up your repository
            - activate custom git hooks
            - set git user name and email
        - commit & push new content of your repository
        - set up MGM server
            - copy there Repo_sync folder
            - create Repo_sync scheduled task
            - export repo_puller credentials
        - copy exported credentials from MGM to local repository, commmit and push it
        - create GPO '$GPOname' that will be used for connecting clients to this solution
            - linking GPO has to be done manually
    - NOTE: every step has to be explicitly confirmed

2) Update of existing installation
    - NO MODIFICATION OF YOUR ENVIRONMENT WILL BE MADE
        - just customization of generic data in repo_content_set_up folder to match your environment
            - merging with your own repository etc has to be done manually
"@

    $choice = ""
    while ($choice -notmatch "^[1|2]$") {
        $choice = Read-Host "Choose install option (1|2)"
    }
    if ($choice -eq 1) {
        $noEnvModification = $false
    }
    else {
        $noEnvModification = $true
    }
}

Clear-Host

if (!$noEnvModification) {
    @"
####################################
#   BEFORE YOU CONTINUE
####################################

- create cloud or locally hosted GIT !private! repository (tested with Azure DevOps but probably will work also with GitHub etc)
   - create READ only account in that repository (repo_puller)
       - create credentials for this account, that can be used in unnatended way (i.e. alternate credentials in Azure DevOps)
   - install newest version of 'Git' and 'Git Credential Manager for Windows' and clone your repository locally
        - using 'git clone' command under account, that has write permission to the repository i.e. yours

   - NOTE:
        - it is highly recommended to use 'Visual Studio Code' editor to work with the repository content because it provides:
            - unified admin experience through repository VSC workspace settings
            - integration & control of GIT
            - auto-formatting of the code etc
        - more details can be found at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md
"@

    _pressKeyToContinue
}

# TODO nekam napsat ze je potreba psremoting

Clear-Host

@"
############################
!!! ANYONE WHO CONTROL THIS SOLUTION IS DE FACTO ADMINISTRATOR ON EVERY COMPUTER CONNECTED TO IT !!!
So:
    - just approved users should have write access to GIT repository
    - for accessing cloud GIT repository, use MFA if possible
    - MGM server (processes repository data and uploads them to share) has to be protected so as the server that hosts that repository share
############################
"@

_pressKeyToContinue
Clear-Host

@"
############################

Your input will be stored to '$iniFile'. So next time you start this script, its content will be automatically used.

Transcript is saved to '$transcript'.

############################
"@

_pressKeyToContinue
Clear-Host
#endregion initial

try {
    #region import variables
    # import variables from ini file
    # '#' can be used for comments, so skip such lines
    if (Test-Path $iniFile) {
        Write-host "- Importing variables from $iniFile" -ForegroundColor Green
        Get-Content $iniFile -ea SilentlyContinue | ? { $_ -and $_ -notmatch "^\s*#" } | % {
            $line = $_
            if (($line -split $divider).count -ge 2) {
                $position = $line.IndexOf($divider)
                $name = $line.Substring(0, $position) -replace "^\s*|\s*$"
                $value = $line.Substring($position + 1) -replace "^\s*|\s*$"
                "   - variable $name` will have value: $value"

                # fill hash so I can later export (updated) variables back to file
                $setupVariable.$name = $value
            }
        }

        _pressKeyToContinue
    }
    #endregion import variables

    Clear-Host

    #region checks
    Write-host "- Checking permissions etc" -ForegroundColor Green

    # # computer isn't in domain
    # if (!$noEnvModification -and !(Get-WmiObject -Class win32_computersystem).partOfDomain) {
    #     Write-Warning "This PC isn't joined to domain. AD related steps will have to be done manually."

    #     ++$skipAD

    #     _continue
    # }

    # is domain admin
    if (!$noEnvModification -and !((whoami /all) -match "Domain Admins|Enterprise Admins")) {
        Write-Warning "You are not member of Domain nor Enterprise Admin group. AD related steps will have to be done manually."

        ++$notADAdmin

        _continue
    }

    # ActiveDirectory PS module is available
    if (!$noEnvModification -and !(Get-Module ActiveDirectory -ListAvailable)) {
        Write-Warning "ActiveDirectory PowerShell module isn't installed (part of RSAT)."

        if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
            if ($isServer) {
                $null = Add-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools
            }
            else {
                try {
                    $null = Get-WindowsCapability -Name "*activedirectory*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop 
                } catch {
                    Write-Warning "Unable to install RSAT AD tools.`nAD related steps will be skipped, so make them manually."
                    ++$noADmodule
                    _pressKeyToContinue
                }
            }
        }
        else {
            Write-Warning "AD related steps will be skipped, so make them manually."
            ++$noADmodule
            _pressKeyToContinue
        }
    }

    # GroupPolicy PS module is available
    if (!$noEnvModification -and !(Get-Module GroupPolicy -ListAvailable)) {
        Write-Warning "GroupPolicy PowerShell module isn't installed (part of RSAT)."

        if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
            if ($isServer) {
                $null = Add-WindowsFeature -Name GPMC -IncludeManagementTools
            }
            else {
                try {
                    $null = Get-WindowsCapability -Name "*grouppolicy*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop 
                } catch {
                    Write-Warning "Unable to install RSAT GroupPolicy tools.`nGPO related steps will be skipped, so make them manually."
                    ++$noGPOmodule
                    _pressKeyToContinue
                }
            }
        }
        else {
            Write-Warning "GPO related steps will be skipped, so make them manually."
            ++$noGPOmodule
            _pressKeyToContinue
        }
    }

    if ($notADAdmin -or $noADmodule) {
        ++$skipAD
    }

    if ($notADAdmin -or $noGPOmodule) {
        ++$skipGPO
    }

    # TODO check that Git Credential Manager for Windows is installed

    # is local administrator
    if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Warning "Not running as administrator. Symlink for using repository PowerShell snippets file in VSC won't be created"
        ++$notAdmin
    
        _pressKeyToContinue
    }
    #endregion checks

    _pressKeyToContinue
    Clear-Host

    _SetVariable MGMServer "the name of the MGM server (will be used for pulling, processing and distribution of repository data to repository share). Use FQDN format (mgmserver.contoso.com)"
    if ($MGMServer -notlike "*.*") {
        throw "$MGMServer isn't in FQDN format (mgmserver.contoso.com)"
    }
    if (!$noADmodule -and !(Get-ADComputer -Filter "name -eq '$MGMServer'")) {
        throw "$MGMServer doesn't exist in AD"
    }

    _saveInput
    Clear-Host


    #region create repo_reader, repo_writer
    Write-Host "- Creating repo_reader, repo_writer AD security groups" -ForegroundColor Green

    if (!$noEnvModification -and !$skipAD -and !(_skip)) {
        'repo_reader', 'repo_writer' | % {
            if (Get-ADGroup -filter "samaccountname -eq '$_'") {
                "   - $_ already exists"
            }
            else {
                if ($_ -match 'repo_reader') {
                    $right = "read"
                }
                else {
                    $right = "modify"
                }
                New-ADGroup -Name $_ -GroupCategory Security -GroupScope Universal -Description "Members has $right permission to repository share content."
                " - created $_"
            }
        }
    }
    else {
        Write-Warning "Skipped!`n`nCreate them manually"
    }
    #endregion create repo_reader, repo_writer

    _pressKeyToContinue
    Clear-Host

    #region adding members to repo_reader, repo_writer
    Write-Host "- Adding members to repo_reader, repo_writer AD groups" -ForegroundColor Green
    "   - add 'Domain Computers' to repo_reader group"
    "   - add 'Domain Admins' and $MGMServer to repo_writer group"
    
    if (!$noEnvModification -and !$skipAD -and !(_skip)) {
        "   - adding 'Domain Computers' to repo_reader group (DCs are not members of this group!)"
        Add-ADGroupMember -Identity 'repo_reader' -Members "Domain Computers"
        "   - adding 'Domain Admins' and $MGMServer to repo_writer group"
        Add-ADGroupMember -Identity 'repo_writer' -Members "Domain Admins", "$MGMServer$"
    }
    else {
        Write-Warning "Skipped! Fill them manually.`n`n - repo_reader should contains computers which you want to join to this solution i.e. 'Domain Computers' (if you choose just subset of computers, use repo_reader and repo_writer for security filtering on lately created GPO $GPOname)`n - repo_writer should contains 'Domain Admins' and $MGMServer server"
    }

    ""
    Write-Warning "RESTART $MGMServer (and rest of the computers) to apply new membership NOW!"
    #endregion adding members to repo_reader, repo_writer
    
    _pressKeyToContinue
    Clear-Host

    #region set up shared folder for repository data
    Write-Host "- Creating shared folder for hosting repository data" -ForegroundColor Green
    _SetVariable repositoryShare "UNC path to folder, where the repository data should be stored (i.e. \\mydomain\dfs\repository)"
    if ($repositoryShare -notmatch "^\\\\[^\\]+\\[^\\]+") {
        throw "$repositoryShare isn't valid UNC path"
    }

    $permissions = "`n`t`t- SHARE`n`t`t`t- Everyone - FULL CONTROL`n`t`t- NTFS`n`t`t`t- SYSTEM, repo_writer - FULL CONTROL`n`t`t`t- repo_reader - READ"

    if (!$noEnvModification -and !(_skip)) {
        "   - Testing, whether '$repositoryShare' exists already"
        try {
            Test-Path $repositoryShare
        }
        catch {
            # in case this script already created that share but this user isn't yet in repo_writer, he will receive access denied error when accessing it
            if ($_ -match "access denied") {
                ++$accessDenied
            }
        }
        if ((Test-Path $repositoryShare -ea SilentlyContinue) -or $accessDenied) {
            Write-Warning "Share '$repositoryShare' already exists.`n`tMake sure, that ONLY following permissions are set:$permissions`n`nNOTE: it's content will be replaced by repository data eventually!"
        }
        else {
            # share or some part of its path doesn't exist
            $isDFS = ""
            while ($isDFS -notmatch "^[Y|N]$") {
                ""
                $isDFS = Read-Host "   - Is '$repositoryShare' DFS share? (Y|N)"
            }

            if ($isDFS -eq "Y") {
                #TODO pridat podporu pro tvorbu DFS share
                Write-Warning "Skipped! Currently this installer doesn't support creation of DFS share.`nMake share manually with ONLY following permissions:$permissions"
            }
            else {
                # creation of non-DFS shared folder
                $repositoryHost = ($repositoryShare -split "\\")[2]
                if (!$noADmodule -and !(Get-ADComputer -Filter "name -eq '$repositoryHost'")) {
                    throw "$repositoryHost doesn't exist in AD"
                }

                $parentPath = "\\" + [string]::join("\", $repositoryShare.Split("\")[2..3])

                if (($parentPath -eq $repositoryShare) -or ($parentPath -ne $repositoryShare -and !(Test-Path $parentPath -ea SilentlyContinue))) {
                    # shared folder doesn't exist, can't deduce local path from it, so get it from the user
                    ""
                    _SetVariable repositoryShareLocPath "local path to folder, which will be than shared as '$parentPath' (on $repositoryHost)"
                }
                else {
                    ""
                    "   - Share $parentPath already exists. Folder for repository data will be created (if necessary) and JUST NTFS permissions will be set."
                    Write-Warning "So make sure, that SHARE permissions are set to: Everyone - FULL CONTROL!"

                    _pressKeyToContinue
                }

                if ($notADAdmin) {
                    while (!$repositoryHostSession) {
                        $repositoryHostSession = New-PSSession -ComputerName $repositoryHost -Credential (Get-Credential -Message "Enter admin credentials for connecting to $repositoryHost through psremoting") -ErrorAction SilentlyContinue
                    }
                }
                else {
                    $repositoryHostSession = New-PSSession -ComputerName $repositoryHost
                }

                Invoke-Command -Session $repositoryHostSession {
                    param ($repositoryShareLocPath, $repositoryShare, $allFunctionDefs)

                    # recreate function from it's definition
                    foreach ($functionDef in $allFunctionDefs) {
                        . ([ScriptBlock]::Create($functionDef))
                    }

                    $shareName = ($repositoryShare -split "\\")[3]

                    if ($repositoryShareLocPath) {
                        # share doesn't exist yet
                        # create folder (and subfolders) and share it
                        if (Test-Path $repositoryShareLocPath) {
                            Write-Warning "$repositoryShareLocPath already exists on $env:COMPUTERNAME!"
                            _continue "Content will be eventually overwritten"
                        }
                        else {
                            [Void][System.IO.Directory]::CreateDirectory($repositoryShareLocPath)

                            # create subfolder structure if UNC path contains them as well
                            $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                            $subfolder = Join-Path $repositoryShareLocPath $subfolder 
                            [Void][System.IO.Directory]::CreateDirectory($subfolder)

                            # share the folder
                            "       - share $repositoryShareLocPath as $shareName"
                            $null = Remove-SmbShare -Name $shareName -Force -Confirm:$false -ErrorAction SilentlyContinue
                            $null = New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess Everyone

                            # set NTFS permission
                            "       - setting NTFS permissions on $repositoryShareLocPath"
                            _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader
                        }
                    }
                    else {
                        # share already exists
                        # create folder for storing repository, set NTFS permissions and check SHARE permissions 
                        $share = Get-SmbShare $shareName
                        $repositoryShareLocPath = $share.path

                        # create subfolder structure if UNC path contains them as well
                        $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                        $subfolder = Join-Path $repositoryShareLocPath $subfolder
                        [Void][System.IO.Directory]::CreateDirectory($subfolder)

                        # set NTFS permission
                        "`n   - setting NTFS permissions on $repositoryShareLocPath"
                        _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader

                        # check/set SHARE permission
                        $sharePermission = Get-SmbShareAccess $shareName
                        if (!($sharePermission | ? { $_.accountName -eq "Everyone" -and $_.AccessControlType -eq "Allow" -and $_.AccessRight -eq "Full" })) {
                            "      - share $shareName doesn't contain valid SHARE permissions, EVERYONE should have FULL CONTROL access (access to repository data is driven by NTFS permissions)."
                            
                            _pressKeyToContinue "Current share $repositoryShare will be un-shared and re-shared with correct SHARE permissions"

                            Remove-SmbShare -Name $shareName -Force -Confirm:$false            
                            New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess EVERYONE
                        }
                        else {
                            "      - share $shareName already has correct SHARE permission, no action needed"
                        }
                    }
                } -argumentList $repositoryShareLocPath, $repositoryShare, $allFunctionDefs

                Remove-PSSession $repositoryHostSession
            }
        }
    }
    else {
        Write-Warning "Skipped!`n`n - Create shared folder '$repositoryShare' manually and set there following permissions:$permissions"
    }
    #endregion set up shared folder for repository data

    _saveInput
    _pressKeyToContinue
    Clear-Host

    #region customize cloned data
    $repo_content_set_up = Join-Path $PSScriptRoot "repo_content_set_up"
    $_other = Join-Path $PSScriptRoot "_other"
    Write-Host "- Customizing generic data to match your environment by replacing '__REPLACEME__<number>' in content of '$repo_content_set_up' and '$_other'" -ForegroundColor Green
    if (!(Test-Path $repo_content_set_up -ea SilentlyContinue)) {
        throw "Unable to find '$repo_content_set_up'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
    }
    if (!(Test-Path $_other -ea SilentlyContinue)) {
        throw "Unable to find '$_other'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
    }

    Write-Host "`n   - Gathering values for replacing __REPLACEME__<number> string:" -ForegroundColor DarkGreen
    "       - in case, you will need to update some of these values in future, clone again this repository, edit content of $iniFile and run this wizard again`n"
    $replacemeVariable = @{
        1 = $repositoryShare
        2 = _setVariable repositoryURL "URL for cloning your own GIT repository. Will be used on MGM server" -passThru
        3 = $MGMServer
        4 = _setVariable computerWithProfile "name of computer(s) (without ending $, divided by comma) that should get:`n       - global Powershell profile (shows number of commits this console is behind in Title etc)`n       - adminFunctions module (Refresh-Console function etc)`n" -passThru
        5 = _setVariable smtpServer "IP or hostname of your SMTP server. Will be used for sending error notifications (recipient will be specified later)" -optional -passThru
        6 = _setVariable adminEmail "recipient(s) email address (divided by comma), that should receive error notifications. Use format it@contoso.com" -optional -passThru
        7 = _setVariable 'from' "sender email address, that should be used for sending error notifications. Use format robot@contoso.com" -optional -passThru
    }

    # replace __REPLACEME__<number> for entered values in cloned files
    $replacemeVariable.GetEnumerator() | % {
        # in files, __REPLACEME__<number> format is used where user input should be placed
        $name = "__REPLACEME__" + $_.name
        $value = $_.value

        # variables that support array convert to "a", "b", "c" format
        if ($_.name -in (4, 6) -and $value -match ",") {
            $value = $value -split "," -replace "\s*$|^\s*"
            $value = $value | % { "`"$_`"" }
            $value = $value -join ", "
        }

        # variable is repository URL, convert it to correct format
        if ($_.name -eq 2) {
            # remove leading http(s):// because it is already mentioned in repo_sync.ps1
            $value = $value -replace "^http(s)?://"
            # remove login i.e. part before @
            $value = $value.Split("@")[-1]
        }

        # remove quotation, replace string is already quoted in files
        $value = $value -replace "^\s*[`"']" -replace "[`"']\s*$"

        "   - replacing: $name for: $value"
        Get-ChildItem $repo_content_set_up, $_other -Include *.ps1, *.psm1, *.xml -Recurse | % {
            (Get-Content $_.fullname) -replace $name, $value | Set-Content $_.fullname
        }

        #TODO zkontrolovat/upozornit na soubory kde jsou replaceme (exclude takovych kde nezadal uzivatel zadnou hodnotu)
    }
    #endregion customize cloned data

    _saveInput
    _pressKeyToContinue
    Clear-Host

    #region warn about __CHECKME__
    Write-Host "- Searching for __CHECKME__ in $repo_content_set_up" -ForegroundColor Green
    $fileWithCheckMe = Get-ChildItem $repo_content_set_up -Recurse | % { if ((Get-Content $_.fullname -ea SilentlyContinue -Raw) -match "__CHECKME__") { $_.fullname } }
    # remove this script from the list
    $fileWithCheckMe = $fileWithCheckMe | ? { $_ -ne $PSCommandPath }
    if ($fileWithCheckMe) {
        Write-Warning "Search for __CHECKME__ string in the following files and decide what to do according to information that follows there (save any changes before continue):"
        $fileWithCheckMe | % { "   - $_`n" }
    }
    #endregion warn about __CHECKME__

    _pressKeyToContinue
    Clear-Host

    #region copy customized repository data to user own repository
    Write-Host "- Copying customized repository data to your own company repository" -ForegroundColor Green
    _SetVariable userRepository "path to ROOT of your locally cloned company repository '$repositoryURL'"

    if (!$noEnvModification -and !(_skip)) {
        if (!(Test-Path (Join-Path $userRepository ".git") -ea SilentlyContinue)) {
            throw "$userRepository isn't cloned GIT repository (.git folder is missing)"
        }

        $result = _copyFolder $repo_content_set_up $userRepository
        if ($err = $result.errMsg) {
            throw "Copy failed:`n$err"
        }
    }
    else {
        Write-Warning "Skipped!`n`n - Copy CONTENT of $repo_content_set_up to ROOT of your locally cloned company repository. Review the changes to prevent loss of any of your customization (preferably merge content of customConfig.ps1 and Variables.psm1 instead of replacing them completely) and COMMIT them"
        _pressKeyToContinue
    }
    #endregion copy customized repository data to user own repository

    _saveInput
    Clear-Host

    #region configure user repository
    Write-Host "- Configuring repository '$userRepository' i.e." -ForegroundColor Green
    @"
   - set GIT user name to '$env:USERNAME'
   - set GIT user email to '$env:USERNAME@$env:USERDNSDOMAIN'
   - create symlink for PowerShell snippets (to VSC profile folder), so VSC can offer these snippets
   - commit & push changes to repository $repositoryURL
   - activates GIT hooks for automation of checks, git push etc
"@

    if (!$noEnvModification -and !(_skip)) {
        $currPath = Get-Location
        Set-Location $userRepository

        # just in case user installed GIT after launch of this console, update PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        "   - setting GIT user name to '$env:USERNAME'"
        git config user.name $env:USERNAME

        "   - setting GIT user email to '$env:USERNAME@$env:USERDNSDOMAIN'"
        git config user.email "$env:USERNAME@$env:USERDNSDOMAIN"

        $VSCprofile = Join-Path $env:APPDATA "Code\User"
        $profilePSsnippets = Join-Path $VSCprofile "snippets"
        $profilePSsnippet = Join-Path $profilePSsnippets "powershell.json"
        $repositoryPSsnippet = Join-Path $userRepository "powershell.json"
        "   - creating symlink '$profilePSsnippet' for '$repositoryPSsnippet', so VSC can offer these PowerShell snippets"
        if (!$notAdmin -and (Test-Path $VSCprofile -ea SilentlyContinue) -and !(Test-Path $profilePSsnippet -ea SilentlyContinue)) {
            [Void][System.IO.Directory]::CreateDirectory($profilePSsnippets)
            $null = New-Item -itemtype symboliclink -path $profilePSsnippets -name "powershell.json" -value $repositoryPSsnippet
        }
        else {
            Write-Warning "Skipped.`n`nYou are not running this script with admin privileges or VSC isn't installed or '$profilePSsnippet' already exists"
        }

        # to avoid message 'warning: LF will be replaced by CRLF'
        $null = _startProcess git "config core.autocrlf false" -outputErr2Std -dontWait
        
        # commit without using hooks, to avoid possible problem with checks (because of wrong encoding, missing PSScriptAnalyzer etc), that could stop it 
        "   - commiting & pushing changes to repository $repositoryURL"
        $null = git add .
        $null = _startProcess git "commit --no-verify -m initial" -outputErr2Std -dontWait
        $null = _startProcess git "push --no-verify" -outputErr2Std

        "   - activating GIT hooks for automation of checks, git push etc"
        $null = _startProcess git 'config core.hooksPath ".\.githooks"'

        # to set default value again
        $null = _startProcess git "config core.autocrlf true" -outputErr2Std -dontWait

        Set-Location $currPath
    }
    else {
        Write-Warning "Skipped!`n`nFollow instructions in $(Join-Path $repo_content_set_up '!!!README!!!.txt') file"
    }
    #endregion configure user repository

    _pressKeyToContinue
    Clear-Host

    #region preparation of MGM server
    $MGMRepoSync = "\\$MGMServer\C$\Windows\Scripts\Repo_sync"
    $userRepoSync = Join-Path $userRepository "custom\Repo_sync"
    Write-Host "- Setting MGM server ($MGMServer) i.e." -ForegroundColor Green
    @"
   - copy Repo_sync folder to '$MGMRepoSync'
   - install newest version of 'GIT'
   - create scheduled task '$taskName' from 'Repo_sync.xml'
   - export 'repo_puller' account credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $MGMServer will be able to read them!)
   - copy exported credentials from $MGMServer to $userRepoSync
   - commit&push exported credentials (so they won't be automatically deleted from $MGMServer, after this solution starts working)
"@

    if (!$noEnvModification -and !(_skip)) {
        "   - copying Repo_sync folder to '$MGMRepoSync'"
        if ($notADAdmin) {
            while (!$MGMServerSession) {
                $MGMServerSession = New-PSSession -ComputerName $MGMServer -Credential (Get-Credential -Message "Enter admin credentials for connecting to $MGMServer through psremoting") -ErrorAction SilentlyContinue
            }
        }
        else {
            $MGMServerSession = New-PSSession -ComputerName $MGMServer
        }

        if ($notADAdmin) {
            $destination = "C:\Windows\Scripts\Repo_sync"

            # remove existing folder, otherwise Copy-Item creates eponymous subfolder and copies the content to it
            Invoke-Command -Session $MGMServerSession {
                param ($destination)
                if (Test-Path $destination -ea SilentlyContinue) {
                    Remove-Item $destination -Recurse -Force
                }
            } -ArgumentList $destination

            Copy-Item -ToSession $MGMServerSession $userRepoSync -Destination $destination -Force -Recurse
        }
        else {
            # copy using admin share
            $result = _copyFolder $userRepoSync $MGMRepoSync 
            if ($err = $result.errMsg) {
                throw "Copy failed:`n$err"
            }
        }

        Invoke-Command -Session $MGMServerSession {
            param ($repositoryShare, $allFunctionDefs)

            # recreate function from it's definition
            foreach ($functionDef in $allFunctionDefs) {
                . ([ScriptBlock]::Create($functionDef))
            }

            $MGMRepoSync = "C:\Windows\Scripts\Repo_sync"
            $taskName = 'Repo_sync'

            "   - checking that $env:COMPUTERNAME is in AD group repo_writer"
            if (!(_getComputerMembership -match "repo_writer")) {
                throw "Check failed. Make sure, that $env:CommonProgramFiles is in repo_writer group and restart it to apply new membership. Than run this script again"
            } 

            "   - installing newest version of 'GIT'"
            _installGIT

            # "   - downloading & installing 'GIT Credential Manager'"
            # _installGITCredManager

            $Repo_syncXML = "$MGMRepoSync\Repo_sync.xml"
            "   - creating scheduled task '$taskName' from $Repo_syncXML"
            _createSchedTask $Repo_syncXML $taskName

            "   - exporting repo_puller account credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $env:COMPUTERNAME will be able to read them!)"
            _exportCred -credential (Get-Credential -Message 'Enter credentials (that can be used in unattended way) for GIT "repo_puller" account, you created earlier') -runAs "NT AUTHORITY\SYSTEM" -xmlPath "$MGMRepoSync\login.xml"

            "   - starting scheduled task '$taskName' to fill $repositoryShare immediately"
            _startSchedTask $taskName

            "      - checking, that the task ends up succesfully"
            while (($result = ((schtasks /query /tn "$taskName" /v /fo csv /nh) -split ",")[6]) -eq '"267009"') {
                # task is running
                Start-Sleep 1
            }
            if ($result -ne '"0"') {
                throw "Task '$taskName' ends up with error ($($result -replace '"')). Check C:\Windows\Temp\Repo_sync.ps1.log on $env:COMPUTERNAME for more information"
            }
        } -ArgumentList $repositoryShare, $allFunctionDefs

        "   - copying exported credentials from $MGMServer to $userRepoSync"
        if ($notADAdmin) {
            Copy-Item -FromSession $MGMServerSession "C:\Windows\Scripts\Repo_sync\login.xml" -Destination "$userRepoSync\login.xml" -force
        }
        else {
            # copy using admin share
            Copy-Item "$MGMRepoSync\login.xml" "$userRepoSync\login.xml" -Force
        }

        Remove-PSSession $MGMServerSession

        "   - committing exported credentials (so they won't be automatically deleted from MGM server, after this solution starts)"
        $currPath = Get-Location
        Set-Location $userRepository
        $null = git add .
        $null = _startProcess git 'commit --no-verify -m "repo_puller creds for $MGMServer"' -outputErr2Std -dontWait
        $null = _startProcess git "push --no-verify" -outputErr2Std
        # git push # push should be done automatically thanks to git hooks
        Set-Location $currPath
    }
    else {
        Write-Warning "Skipped!`n`nFollow instruction in configuring MGM server section https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#on-server-which-will-be-used-for-cloning-and-processing-cloud-repository-data-and-copying-result-to-dfs-ie-mgm-server"
    }
    #endregion preparation of MGM server

    _pressKeyToContinue
    Clear-Host

    #region create GPO
    $GPObackup = Join-Path $_other "PS_env_set_up GPO"
    Write-Host "- Creating GPO $GPOname for joining computers to this solution" -ForegroundColor Green
    if (!$noEnvModification -and !$skipGPO -and !(_skip)) {
        if (Get-GPO $GPOname -ErrorAction SilentlyContinue) {
            $choice = ""
            while ($choice -notmatch "^[Y|N]$") {
                $choice = Read-Host "GPO $GPOname already exists. Replace it? (Y|N)"
            }
            if ($choice -eq "Y") {
                $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname 
            }
            else {
                Write-Warning "Skipped creation of $GPOname"
            }
        }
        else {
            $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname -CreateIfNeeded 
        }
    }
    else {
        Write-Warning "Skipped!`n`nCreate GPO by following https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#in-active-directory-1 or using 'Import settings...' wizard in GPMC. GPO backup is stored in '$GPObackup'"
    }
    #endregion create GPO

    
    _pressKeyToContinue
    Clear-Host

    #region finalize installation
    Write-Host "FINALIZING INSTALLATION" -ForegroundColor Green
    if (!$noEnvModification -and !$skipAD -and !$skipGPO -and !$notAdmin) {
        # enought rights to process all steps
    }
    else {
        "- DO NOT FORGET TO DO ALL SKIPPED TASKS MANUALLY"
    }
    Write-Warning "- Link GPO $GPOname to OU(s) with computers, that should be driven by this tool.`n    - don't forget, that also $MGMServer server has to be in such OU!"
    @"
    - for ASAP test that synchronization is working:
        - run on client command 'gpupdate /force' to create scheduled task $GPOname
        - run that sched. task and check the result in C:\Windows\Temp\$GPOname.ps1.log
"@
    #endregion finalize installation

    _pressKeyToContinue
    Clear-Host

    Write-Host "GOOD TO KNOW" -ForegroundColor green
    @"
- For immediate refresh of clients data (and console itself) use function Refresh-Console
    - NOTE: available only on computers defined in Variables module in `$computerWithProfile
- For real world use cases check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md
- For brief video introduction check https://youtu.be/-xSJXbmOgyk
- To understand various part of this solution check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md and https://youtu.be/R3wjRT0zuOk
- To master Modules deployment check \modules\modulesConfig.ps1
- To master Custom section features check \custom\customConfig.ps1

ENJOY :)

"@
}
catch {
    $e = $_.Exception
    $line = $_.InvocationInfo.ScriptLineNumber
    Write-Host "$e (file: $PSCommandPath line: $line)" -ForegroundColor Red
    break
}
finally {
    try {
        Remove-PSSession -Session $repositoryHostSession
        Remove-PSSession -Session $MGMServerSession
    }
    catch {}
}