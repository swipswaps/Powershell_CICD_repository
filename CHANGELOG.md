# Changelog

## [2.0.21] - 2020-04-24
### Bug fixes
- fixed detection of renamed files in pre-commit.ps1
### Changed
- relaxed checks for sched. task xml validity + handle xml without author in PS_env_set_up.ps1


## [2.0.20] - 2020-03-27
### Bug fixes
- fixed bug that caused deletion of scheduled tasks (that were created by this solution) in case, that computer was defined in multiple objects in customConfig variable
### Changed
- scheduled task validity check in pre-commit.ps1 now instead of URI tag checks for existence of Author tag in task XML definition
  - so sched. tasks exported from Windows Server 2012 can be used too without problem 


## [2.0.19] - 2020-03-18
### Changed
- translation of git hooks


## [2.0.18] - 2020-03-13
### Changed
- translation of customConfig.ps1
- translation of modulesConfig.ps1
- translation of repo_sync.ps1
- translation of PS_env_st_up.ps1


## [2.0.17] - 2020-03-09
### Changed
- translation of profile.ps1
### Bug fixes
- another fix for showing "how many commits behind" number in ISE title


## [2.0.16] - 2020-03-09
### Bug fixes
- fixed showing "how many commits behind" number in ISE title


## [2.0.15] - 2020-01-02
### Bug fixes
- output git errors in repo_sync.ps1 as error objects, so try{} catch{} block works as exptected


## [2.0.14] - 2019-12-18
### Added
- console Title now shows number of commits, this console is "behind" i.e. how old are data you are working with
![How new Title looks like](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/_other/commitBehind.JPG)

(so you have a hint, how urgent is to start new console (to be able to work with new repository content), or run Refresh-Console to get new content to this console)

beware, that it sais, how much "behind" is your console to your system state, not git repository itself


## [2.0.13] - 2019-11-25
### Bug fixes
- missing computerName in sent emails (from PS_env_set_up)
- double question "Are you sure you want to continue in commit?" in pre-commit
### Changed
- better examples in customConfig
- quote output of TAB completition in PS profile


## [2.0.12] - 2019-11-21
### Changed
- compatibility check is now voluntary because of it's impact on pre-commit checks performance
  - to enable check, just uncomment rules section in PSScriptAnalyzerSettings.psd1


## [2.0.11] - 2019-11-20
### Changed
- profile.ps1 cleanup
- move functions from profile.ps1 to separate adminFunctions module


## [2.0.10] - 2019-11-12
### Bug fixes
- fixed bug in pre-commit which lead to ignore files with spaces in variable $filesToCommitNoDEL
  - such files start with " in git.exe status --porcelain output


## [2.0.9] - 2019-11-01
### Added
- automatic scheduled task creation from xml saved in Custom section (modification and deletion if not needed anymore)
  - so now you can automatically distribute as scripts as scheduled task itself (that should run them). No GPO preferences needed
  - check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) for getting better insight


## [2.0.8] - 2019-10-31
### Bug fixes
- fixed bug in PS_env_set_up that caused error in synchronization on computers, that should obtain global PS profile


## [2.0.7] - 2019-10-24
### Bug fixes
- fixed check for modules existence (now check also scripts2module path) in pre-commit


## [2.0.6] - 2019-10-24
### Bug fixes
- fixed not working limiting access to Custom folder stored in DFS share when used variables (from module Variables) 
### Added
- limiting access to modules stored in DFS share to just computers listed in $modulesConfig computerName key. No other machines can access them
### Changed
- better log output for repo_sync.ps1 script


## [2.0.5] - 2019-10-16
### Changed
- important comments and error messages changed to english


## [2.0.4] - 2019-10-4
### Added
- possibility to automatically sign Powershell code
  - just set up and uncomment definition of $signingCert variable in repo_sync.ps1 


## [2.0.3] - 2019-10-3
### Added
- possibility to sync modules just to chosen computers (defined in modulesConfig.ps1)
### Changed 
- $config variable defined in customConfig.ps1 renamed to $customConfig to honor name of the script file and be more unique
- repo_sync.ps1 now sync changes to DFS everytime, not just in case, some new data was pulled from cloud repo
### Bug fixes
- minor fixes


## [2.0.2] - 2019-10-1
### Added
- check, that commited scripts are compatible with Powershell 3.0 (defined in PSScriptAnalyzerSettings.psd1, so edit it, if you wish to check PS Core compatibility etc)


## [2.0.1] - 2019-9-27
### Bug fixes
- minor fixes


## [2.0.0] - 2019-9-22
### Breaking change
- $config key customNTFS was renamed to customDestinationNTFS
- $config key customShareNTFS was renamed to customSourceNTFS

### Bug fixes
- Repo_sync newly works with most actual data (loads Variables module and customConfig.ps1 right from local cloned repo, prior to loading from DFS share, which could lead to problems in some situations)

### Added
- Granting access to global Powershell profile (scripts2root\profile.ps1) stored in DFS to just computers listed in $computerWithProfilefolders. No other machines can access it.
- Possibility to copy Custom folder to any given local or shared path
- Possibility to copy just content of Custom folder
- Validation of $config variable stored in customConfig.ps1
- Multiple accounts could be defined in customDestinationNTFS (customNTFS)
- Warn about commited files, that contain #FIXME comment
- TAB completition of computerName parametr in any command defined in Scripts module through using Register-ArgumentCompleter in profile.ps1

### Changed 
- Update-Repo and Export-ScriptsToModule functions was moved to Repo_sync.ps1 


## [1.0.3] - 2019-9-2
### Added
- Possibility to define custom share NTFS rights for folders in Custom. Intended for limiting read access to folders stored in share/DFS, in case the folder doesn't have computerName attribute in customConfig, etc access isn't limited already.


## [1.0.2] - 2019-8-30
### Changed
- Later import of the Variables module in PS_env_set_up.ps1 script. To work with current data when synchronyzing profile and Custom section.


## [1.0.1] - 2019-8-30
### Added
- Granting access to folders in DFS repository "Custom" to just computers, which should download this content. Non other machines can access it.


## [1.0.0] - 2019-8-29
### Added
- Initial commit