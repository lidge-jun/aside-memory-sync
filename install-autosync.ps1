# install-autosync.ps1 - first-class PowerShell entry. Forwards $args to install-autosync.sh.
# No policy lives here. Git for Windows bash is located by bin/invoke-git-bash.ps1.
. "$PSScriptRoot\bin\invoke-git-bash.ps1"
Invoke-GitBash "$PSScriptRoot\install-autosync.sh" @args
