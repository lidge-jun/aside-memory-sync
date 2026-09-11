# hub-setup.ps1 - first-class PowerShell entry. Forwards $args to hub-setup.sh.
# No policy lives here. Git for Windows bash is located by bin/invoke-git-bash.ps1.
. "$PSScriptRoot\bin\invoke-git-bash.ps1"
Invoke-GitBash "$PSScriptRoot\hub-setup.sh" @args
