# PowerShell Script to Setup and Run the VersionOne Story Copier Server

param(
    # Internal flag to indicate the script was relaunched for elevation (used by install step)
    [switch]$RelaunchedForInstall
)

# --- Handle Relaunch for Installation FIRST ---
if ($PSBoundParameters.ContainsKey('RelaunchedForInstall')) {
    Write-Host "Script relaunched for Node.js installation." -ForegroundColor Cyan

    # Assume elevation succeeded if we got here via Start-Process -Verb RunAs
    Write-Host "Running with elevated privileges for installation (assumed)." -ForegroundColor Green

    # --- Perform ONLY Winget Install --- 
    try {
        # Check winget exists
        winget --version *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Winget command not found in elevated process. Please install Node.js manually from https://nodejs.org/ or ensure Winget is installed and in PATH."
            Exit 1
        }

        Write-Host "Running: winget install OpenJS.NodeJS --accept-package-agreements --accept-source-agreements" -ForegroundColor Gray
        winget install OpenJS.NodeJS --accept-package-agreements --accept-source-agreements

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Winget failed to install Node.js in elevated process. Please try installing Node.js manually from https://nodejs.org/"
            Exit 1
        }

        Write-Host "Node.js installation completed via Winget." -ForegroundColor Yellow
        # --- Auto-relaunch WITHOUT install flag --- 
        Write-Host "Attempting to automatically restart the script in this elevated session to continue..." -ForegroundColor Cyan
        try {
            $scriptPath = $MyInvocation.MyCommand.Path
            # Arguments for the NEXT instance: run the script normally (no -RelaunchedForInstall)
            $arguments = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $scriptPath
            )
            
            Write-Host "Starting new process to continue script execution..." -ForegroundColor Gray
            # Start in the same elevated context, but as a new process so PATH updates apply
            $newProcess = Start-Process powershell.exe -ArgumentList $arguments -PassThru -ErrorAction Stop
            
            # Brief verification that the process started
            Start-Sleep -Milliseconds 300
            if ($newProcess -and !$newProcess.HasExited) {
                Write-Host "New process started successfully. Exiting installation instance." -ForegroundColor Green
                Exit 0
            } else {
                Write-Error "New process failed to start properly. Please close this terminal and run the script again manually."
                Exit 1
            }
        } catch {
             Write-Error "Failed to automatically restart the script after installation. Please close this terminal and run the script again manually. Error: $($_.Exception.Message)"
             Exit 1
        }
        # --- End Auto-relaunch ---

    } catch {
        Write-Error "Error during Node.js installation attempt via Winget in elevated process. Please install manually from https://nodejs.org/. Error: $($_.Exception.Message)"
        Exit 1
    }
    # --- End Winget Install Block (for relaunched instance) ---
}

# --- Script continues only if NOT relaunched for install --- 

Write-Host "Script execution started (standard run)."

# --- Check for Node.js --- 
Write-Host "Checking for Node.js installation..." -ForegroundColor Cyan
$nodeExists = $false
try {
    # Try executing node -v. Redirect output to null, check exit code.
    node --version *> $null 
    if ($LASTEXITCODE -eq 0) {
        $nodeExists = $true
        Write-Host "Node.js found." -ForegroundColor Green
    } else {
        Write-Host "Node.js not found in PATH." -ForegroundColor Yellow
    }
} catch {
    # Node.js not installed or not in PATH
    Write-Host "Node.js not found (command failed)." -ForegroundColor Yellow
}

# --- Install Node.js if needed (in the *original* run) ---
if (-not $nodeExists) {
    Write-Host "Node.js not found. Attempting installation..." -ForegroundColor Yellow

    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

    if (-NOT $IsElevated) {
        # Not elevated, attempt to relaunch.
        Write-Warning "Node.js installation requires elevated privileges. Attempting to relaunch with elevation..."
        Write-Host "Please click 'Yes' on the UAC prompt that appears..." -ForegroundColor Yellow
        
        try {
            $scriptPath = $MyInvocation.MyCommand.Path
            # Simplified argument construction to avoid quoting issues
            $arguments = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $scriptPath,
                "-RelaunchedForInstall"
            )
            
            Write-Host "Attempting elevation..." -ForegroundColor Gray
            
            # Start the elevated process and capture the process object
            $elevatedProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru -ErrorAction Stop
            
            # Wait a moment to see if the process actually started
            Start-Sleep -Milliseconds 500
            
            # Check if the process is still running (indicates UAC was accepted)
            if ($elevatedProcess -and !$elevatedProcess.HasExited) {
                Write-Host "Elevated process started successfully. Exiting original process..." -ForegroundColor Green
                Exit 0
            } else {
                Write-Error "Elevated process failed to start or exited immediately. This usually means UAC was cancelled or denied."
                Write-Host "Please try running the script again and click 'Yes' on the UAC prompt, or run PowerShell as Administrator manually." -ForegroundColor Yellow
                Exit 1
            }
            
        } catch [System.ComponentModel.Win32Exception] {
            # This specific exception occurs when UAC is cancelled
            Write-Error "UAC prompt was cancelled or elevation was denied. Please run the script again and accept the elevation, or run PowerShell as Administrator manually."
            Exit 1
        } catch {
            Write-Error "Failed to start elevated process. Please run the script manually using 'Run as administrator'. Error: $($_.Exception.Message)"
            Write-Host "Error Type: $($_.Exception.GetType().Name)" -ForegroundColor Red
            Exit 1
        }
    } else {
        # Already elevated in the *original* run. Proceed with install directly.
        Write-Host "Running with elevated privileges. Proceeding with Winget installation directly..." -ForegroundColor Green

        # --- Perform Winget Install (directly in elevated original run) --- 
        try {
            # Check winget exists
            winget --version *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Winget command not found. Please install Node.js manually from https://nodejs.org/ or ensure Winget is installed and in PATH."
                Exit 1
            }

            Write-Host "Running: winget install OpenJS.NodeJS --accept-package-agreements --accept-source-agreements" -ForegroundColor Gray
            winget install OpenJS.NodeJS --accept-package-agreements --accept-source-agreements

            if ($LASTEXITCODE -ne 0) {
                Write-Error "Winget failed to install Node.js. Please try installing Node.js manually from https://nodejs.org/"
                Exit 1
            }
            
            # Node.js installed successfully - Now continue instead of exiting
            Write-Host "Node.js installation completed via Winget. Continuing script execution in this elevated window..." -ForegroundColor Green
            Write-Host "Allowing a moment for system PATH to potentially update..." -ForegroundColor Gray
            Start-Sleep -Seconds 3 # Give system a moment, may not be enough

            # Re-check if node is now detectable - PATH changes might not reflect immediately
            Write-Host "Re-checking for Node.js command availability..." -ForegroundColor Cyan
            $nodeExists = $false # Reset before check
             try {
                 node --version *> $null
                 if ($LASTEXITCODE -eq 0) {
                     $nodeExists = $true
                     Write-Host "Node.js command is now detectable in this session." -ForegroundColor Green
                 } else {
                     Write-Warning "Node.js installed, but 'node' command still not found in PATH immediately in this session. `npm start` might fail. If it does, please close and reopen this terminal."
                 }
             } catch {
                  Write-Warning "Node.js installed, but executing 'node --version' failed immediately. `npm start` might fail. If it does, please close and reopen this terminal."
             }
             
             # If node still isn't detected, we cannot reliably continue to 'npm start'
             if (-not $nodeExists) {
                  Write-Error "Failed to detect Node.js command in PATH immediately after installation. Cannot proceed automatically. Please close and reopen this terminal, then run the script again."
                  Exit 1 # Exit because npm start will fail
             }

        } catch {
            Write-Error "Error during Node.js installation attempt via Winget. Please install manually from https://nodejs.org/. Error: $($_.Exception.Message)"
            Exit 1
        }
        # --- End Winget Install Block (for elevated original run) ---
        # Execution will now naturally fall through to the rest of the script
    }
}

# --- Script continues ONLY IF Node.js exists --- 

# Exit script immediately if any command fails (Optional - uncomment if desired)
# $ErrorActionPreference = 'Stop' 

Write-Host "Node.js found. Proceeding with server setup..." -ForegroundColor Cyan

# --- Check for HTTPS_PROXY Environment Variable --- 
$httpsProxy = [System.Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Process")

if (-not $httpsProxy) {
    $setupProxy = Read-Host "NTLM Proxy: HTTPS_PROXY variable not set. Do you want to set it up now? (y/n)"
    
    if ($setupProxy -eq 'y' -or $setupProxy -eq 'Y') {
        # Get proxy server details
        $proxyServer = Read-Host "Enter proxy server address (e.g., proxy.example.com:8080)"
        
        # Get credentials
        $username = Read-Host "Enter your NTLM username"
        
        # Get password with confirmation
        $passwordsMatch = $false
        $securePassword = $null # Initialize to null
        while (-not $passwordsMatch) {
            if ($securePassword) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)); $securePassword = $null }
            $securePassword = Read-Host "Enter your NTLM password" -AsSecureString
            $securePasswordConfirm = Read-Host "Confirm your password" -AsSecureString
            
            # Convert secure strings for comparison
            $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
            $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePasswordConfirm)
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
            $passwordConfirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
            
            # Clear sensitive BSTRs immediately after conversion
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
            
            if ($password -eq $passwordConfirm) {
                $passwordsMatch = $true
            } else {
                Write-Host "Passwords do not match. Please try again." -ForegroundColor Red
            }
            # Clear confirmation SecureString
            $securePasswordConfirm.Dispose()
        }
        
        # Assuming domain might be needed for NTLM proxy format
        $domain = Read-Host "Enter your NTLM domain (e.g., MYDOMAIN)"
        
        # Format the HTTPS_PROXY value (URL encode domain\username)
        $encodedUser = [uri]::EscapeDataString("${domain}\${username}")
        $encodedPassword = [uri]::EscapeDataString($password)
        $proxyValue = "http://${encodedUser}:${encodedPassword}@${proxyServer}"
        
        # Clear plain text password variable
        Remove-Variable password, passwordConfirm -ErrorAction SilentlyContinue
        
        # Set the environment variable for the current process
        [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyValue, "Process")
        Write-Host "HTTPS_PROXY set for this session." -ForegroundColor Green
        
        # Optionally, ask if they want to set it permanently
        $setPermanent = Read-Host "Do you want to set this permanently for your user account? (This modifies user environment variables) (y/n)"
        if ($setPermanent -eq 'y' -or $setPermanent -eq 'Y') {
            try {
                # Setting User level variables typically does not require elevation
                [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyValue, "User")
                Write-Host "HTTPS_PROXY set permanently for your user account. You may need to restart your terminal or log out/in for it to take effect in other applications." -ForegroundColor Green
            } catch {
                Write-Error "Failed to set permanent environment variable for user: $($_.Exception.Message)"
            }
        }
        # Clear final SecureString
        if ($securePassword) { $securePassword.Dispose() }
    }
}

# --- Navigate to Script Directory --- 
if ($PSScriptRoot) {
    Write-Host "Navigating to script directory: $PSScriptRoot" -ForegroundColor Cyan
    Set-Location $PSScriptRoot
} else {
    Write-Warning "Could not determine script directory. Assuming current directory: $PWD"
}

# --- Check for package.json --- 
Write-Host "Checking for package.json..." -ForegroundColor Cyan
if (-not (Test-Path -Path .\package.json -PathType Leaf)) {
    Write-Error "package.json not found in the current directory ($PWD). Cannot proceed."
    Exit 1
}
Write-Host "package.json found." -ForegroundColor Green

# --- Run npm start directly --- 
Write-Host "Starting the Node.js server (npm start)..." -ForegroundColor Cyan
Write-Host "The application should become available at http://localhost:3000" -ForegroundColor Cyan
Write-Host "Press CTRL+C here to stop the server when you are finished." -ForegroundColor Yellow

# Attempt to open the browser slightly before starting the server (it might 404 initially)
try {
    Write-Host "Attempting to open application in default browser..." -ForegroundColor Gray
    Start-Process "http://localhost:3000"
    Start-Sleep -Seconds 2 # Give browser a moment before server potentially blocks console
} catch {
    Write-Warning "Could not automatically open browser. Please navigate to http://localhost:3000 manually once the server starts. Error: $($_.Exception.Message)"
}

# Execute npm start in the foreground. The script will wait here until CTRL+C is pressed.
# Ensure HTTPS_PROXY is available if set earlier and needed by npm
if ($httpsProxy) {
    $env:HTTPS_PROXY = $httpsProxy
}

npm start

# Execution will only reach here after npm start is terminated (e.g., by CTRL+C)
Write-Host "Server process terminated." -ForegroundColor Yellow