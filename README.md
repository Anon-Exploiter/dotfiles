# dotfiles
Finally time to create one!?

## Kali Setup

Created the `script.sh` file through ChatGPT (wasted few hours) to help with installation and automation of Kali VM setup. Using an old version of Kali on new projects with updates messes everything up. This should help. 

```bash
wget https://raw.githubusercontent.com/Anon-Exploiter/dotfiles/refs/heads/main/script.sh
sudo bash ./script.sh
```


## Windows Setup

In WSL

```bash
sudo apt-get -y update
sudo apt-get -y install -y python3-pip python3-venv git
cd /mnt/d/scripts/dotfiles
mkdir -p windows
python3 -m venv ansible-venv
source ./ansible-venv/bin/activate
pip install --upgrade pip
pip install ansible pywinrm requests-ntlm
```

In Windows VM

```powershell
# enable basic WinRM quickconfig
winrm quickconfig -q

# Pick the active IPv4 interface that has the default route
$ifIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
  Sort-Object RouteMetric,ifMetric | Select-Object -First 1 -ExpandProperty ifIndex)
if (-not $ifIndex) {
  Write-Host "No default IPv4 route found. Falling back to any 'Connected' interface."
  $ifIndex = (Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.ConnectionState -eq 'Connected'} |
    Sort-Object InterfaceMetric | Select-Object -First 1 -ExpandProperty InterfaceIndex)
}

# Set network category to Private
if ($ifIndex) {
  $prof = Get-NetConnectionProfile -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
  if ($prof.NetworkCategory -ne 'Private') {
    Set-NetConnectionProfile -InterfaceIndex $ifIndex -NetworkCategory Private
  }
}

# Enable Basic and unencrypted comms
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/client '@{TrustedHosts="*"}'

# Ensure WinRM running and firewall open
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinRM' -Name Start -Type DWord -Value 2
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinRM' -Name DelayedAutoStart -Type DWord -Value 0

Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM
New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow

# Verify Config
winrm get winrm/config/service
winrm get winrm/config/client
winrm enumerate winrm/config/Listener


# Restart Network adapter if internet does not work 
$alias = (Get-NetIPConfiguration |
          Where-Object IPv4DefaultGateway |
          Select-Object -First 1 -ExpandProperty InterfaceAlias)

Restart-NetAdapter -Name $alias -Confirm:$false


# Get the ipaddress
ipconfig
```