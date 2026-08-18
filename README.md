# appsRefresh

A multithreaded PowerShell script designed to automate bulk software installation and updates on Windows using **Windows Package Manager (`winget`)** driven by a simple CSV manifest.

<img width="944" height="772" alt="appsRefresh" src="https://github.com/user-attachments/assets/8ce0df17-5081-4a0a-bab9-5c9069616e93" />

## 🌟 Key Features

- **Parallel Status Checks**: Scans installed applications and available repository updates concurrently across multiple background workers.
- **Safe Sequential Execution**: Runs `winget` installation and upgrade setups one at a time to prevent resource contention or installer conflicts.
- **Interactive Live Dashboard**: Features a real-time terminal UI displaying task progress bars (Check, Action, and Total), timer metrics (Elapsed & ETA), live status updates per app, and a bottom panel streaming output directly from `winget`.
- **Automatic Administrator Elevation**: Prompts for required UAC administrator rights seamlessly at launch.
- **Automatic Retry Mechanism**: Handles transient network/installer glitches by automatically retrying failed installations up to a configurable threshold.
- **Detailed Audit Logging**: Outputs operational events and detailed error stream capture to `appsRefresh.log`.



## 📋 Requirements

* **Windows 10 / 11** or **Windows Server 2019/2022**
* **PowerShell 5.1** or **PowerShell 7+**
* **Windows Package Manager (`winget`)** (installed via *App Installer* from the Microsoft Store)
* Administrator privileges (the script handles auto-elevation if required)



## 🚀 Quick Start

### 1. File Structure
Keep the script and your CSV list in the same folder:

```text
📁 appsRefresh/
├── 📄 appsRefresh.ps1
└── 📊 apps.csv
```

### 2. Configure `apps.csv`
Create or edit `apps.csv`. The file **must** contain a header with the column `AppID`:

```csv
AppID
Git.Git
7zip.7zip
Google.Chrome
VideoLAN.VLC
Microsoft.VisualStudioCode
```

> **Tip:** You can find exact package IDs using `winget search <appname>`.

### 3. Run the Script
Open PowerShell and run the script:

```powershell
.\appsRefresh.ps1
```

If launched without Administrator privileges, the script will request UAC elevation automatically.



## ⚙️ Parameters & Usage

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-CsvPath` | `string` | `.\apps.csv` | Path to the target CSV file containing the `AppID` list. |
| `-CheckWorkers` | `int` | `2` | Number of parallel worker threads used during the check phase. |
| `-ActionRetries` | `int` | `2` | Number of automatic retries attempted for failed installs/upgrades. |



### Examples

**Custom CSV Path:**
```powershell
.\appsRefresh.ps1 -CsvPath "C:\Deployment\software.csv"
```

**Faster Parallel Checks:**
```powershell
.\appsRefresh.ps1 -CheckWorkers 4
```

**Custom Retries & Worker Settings:**
```powershell
.\appsRefresh.ps1 -CsvPath ".\my_apps.csv" -CheckWorkers 4 -ActionRetries 3
```



## 🛠️ How It Works

1. **Pre-Flight Inspection**: Validates environment requirements (`winget` existence, CSV existence, header format) and previews the target application list.
2. **Parallel Check Phase**: Launches `$CheckWorkers` background threads to execute non-destructive `winget list` and `winget show` commands to identify installed versions vs. available updates.
3. **Sequential Action Phase**: Filters applications that need action (`Install` or `Update`) and queues them into a sequential pipeline execution engine.
4. **Live Terminal UI**: Renders a custom live console dashboard showing progress percentages, elapsed time (EL), estimated time remaining (ETA), and active task states.
5. **Final Summary Report**: Displays a detailed breakdown of results (`Total evaluated`, `Up to date`, `Newly installed`, `Updated`, `Failed`).



## 🔍 Troubleshooting

- **Error `0x8a15000f` (`winget` source error)**:
  If `winget` fails to resolve sources, register the default source package manually:
  ```powershell
  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.Winget.Source_8wekyb3d8bbwe
  ```
- **Execution Policy Restriction**:
  If script execution is disabled on your system, launch with:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\appsRefresh.ps1
  ```
  

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/I3I5MBHBZ)
