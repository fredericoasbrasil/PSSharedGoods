﻿function Get-WinADForestDetails {
    [CmdletBinding()]
    param(
        [alias('ForestName')][string] $Forest,
        [string[]] $ExcludeDomains,
        [string[]] $ExcludeDomainControllers,
        [alias('Domain', 'Domains')][string[]] $IncludeDomains,
        [alias('DomainControllers', 'ComputerName')][string[]] $IncludeDomainControllers,
        [switch] $SkipRODC,
        [string] $Filter = '*',
        [switch] $TestAvailability,
        [ValidateSet('All', 'Ping', 'WinRM', 'PortOpen', 'Ping+WinRM', 'Ping+PortOpen', 'WinRM+PortOpen')] $Test = 'All',
        [int[]] $Ports = 135,
        [int] $PortsTimeout = 100,
        [int] $PingCount = 1,
        [switch] $Extended,
        [System.Collections.IDictionary] $ExtendedForestInformation
    )
    if ($Global:ProgressPreference -ne 'SilentlyContinue') {
        $TemporaryProgress = $Global:ProgressPreference
        $Global:ProgressPreference = 'SilentlyContinue'
    }

    if (-not $ExtendedForestInformation) {
        # standard situation, building data from AD
        $Findings = [ordered] @{ }
        try {
            if ($Forest) {
                $ForestInformation = Get-ADForest -ErrorAction Stop -Identity $Forest
            } else {
                $ForestInformation = Get-ADForest -ErrorAction Stop
            }
        } catch {
            Write-Warning "Get-WinADForestDetails - Error discovering DC for Forest - $($_.Exception.Message)"
            return
        }
        if (-not $ForestInformation) {
            return
        }
        $Findings['Forest'] = $ForestInformation
        $Findings['ForestDomainControllers'] = @()
        $Findings['QueryServers'] = @{ }
        $Findings['DomainDomainControllers'] = @{ }
        [Array] $Findings['Domains'] = foreach ($_ in $ForestInformation.Domains) {
            if ($IncludeDomains) {
                if ($_ -in $IncludeDomains) {
                    $_.ToLower()
                }
                # We skip checking for exclusions
                continue
            }
            if ($_ -notin $ExcludeDomains) {
                $_.ToLower()
            }
        }
        [Array] $Findings['ForestDomainControllers'] = foreach ($Domain in $Findings.Domains) {
            try {
                $DC = Get-ADDomainController -DomainName $Domain -Discover -ErrorAction Stop
            } catch {
                Write-Warning "Get-WinADForestDetails - Error discovering DC for domain $Domain - $($_.Exception.Message)"
                continue
            }
            if ($Domain -eq $Findings['Forest']['Name']) {
                $Findings['QueryServers']['Forest'] = $DC
            }
            $Findings['QueryServers']["$Domain"] = $DC
            [Array] $AllDC = try {
                try {
                    $DomainControllers = Get-ADDomainController -Filter $Filter -Server $DC.HostName[0] -ErrorAction Stop
                } catch {
                    Write-Warning "Get-WinADForestDetails - Error listing DCs for domain $Domain - $($_.Exception.Message)"
                    continue
                }
                foreach ($S in $DomainControllers) {
                    if ($IncludeDomainControllers.Count -gt 0) {
                        If (-not $IncludeDomainControllers[0].Contains('.')) {
                            if ($S.Name -notin $IncludeDomainControllers) {
                                continue
                            }
                        } else {
                            if ($S.HostName -notin $IncludeDomainControllers) {
                                continue
                            }
                        }
                    }
                    if ($ExcludeDomainControllers.Count -gt 0) {
                        If (-not $ExcludeDomainControllers[0].Contains('.')) {
                            if ($S.Name -in $ExcludeDomainControllers) {
                                continue
                            }
                        } else {
                            if ($S.HostName -in $ExcludeDomainControllers) {
                                continue
                            }
                        }
                    }
                    $Server = [ordered] @{
                        Domain                 = $Domain
                        HostName               = $S.HostName
                        Name                   = $S.Name
                        Forest                 = $ForestInformation.RootDomain
                        Site                   = $S.Site
                        IPV4Address            = $S.IPV4Address
                        IPV6Address            = $S.IPV6Address
                        IsGlobalCatalog        = $S.IsGlobalCatalog
                        IsReadOnly             = $S.IsReadOnly
                        IsSchemaMaster         = ($S.OperationMasterRoles -contains 'SchemaMaster')
                        IsDomainNamingMaster   = ($S.OperationMasterRoles -contains 'DomainNamingMaster')
                        IsPDC                  = ($S.OperationMasterRoles -contains 'PDCEmulator')
                        IsRIDMaster            = ($S.OperationMasterRoles -contains 'RIDMaster')
                        IsInfrastructureMaster = ($S.OperationMasterRoles -contains 'InfrastructureMaster')
                        OperatingSystem        = $S.OperatingSystem
                        OperatingSystemVersion = $S.OperatingSystemVersion
                        OperatingSystemLong    = ConvertTo-OperatingSystem -OperatingSystem $S.OperatingSystem -OperatingSystemVersion $S.OperatingSystemVersion
                        LdapPort               = $S.LdapPort
                        SslPort                = $S.SslPort
                        DistinguishedName      = $S.ComputerObjectDN
                        Pingable               = $null
                        WinRM                  = $null
                        PortOpen               = $null
                        Comment                = ''
                    }
                    if ($TestAvailability) {
                        if ($Test -eq 'All' -or $Test -like 'Ping*') {
                            $Server.Pingable = Test-Connection -ComputerName $Server.IPV4Address -Quiet -Count $PingCount
                        }
                        if ($Test -eq 'All' -or $Test -like '*WinRM*') {
                            $Server.WinRM = (Test-WinRM -ComputerName $Server.HostName).Status
                        }
                        if ($Test -eq 'All' -or '*PortOpen*') {
                            $Server.PortOpen = (Test-ComputerPort -Server $Server.HostName -PortTCP $Ports -Timeout $PortsTimeout).Status
                        }
                    }
                    [PSCustomObject] $Server
                }
            } catch {
                [PSCustomObject]@{
                    Domain                   = $Domain
                    HostName                 = ''
                    Name                     = ''
                    Forest                   = $ForestInformation.RootDomain
                    IPV4Address              = ''
                    IPV6Address              = ''
                    IsGlobalCatalog          = ''
                    IsReadOnly               = ''
                    Site                     = ''
                    SchemaMaster             = $false
                    DomainNamingMasterMaster = $false
                    PDCEmulator              = $false
                    RIDMaster                = $false
                    InfrastructureMaster     = $false
                    LdapPort                 = ''
                    SslPort                  = ''
                    DistinguishedName        = ''
                    Pingable                 = $null
                    WinRM                    = $null
                    PortOpen                 = $null
                    Comment                  = $_.Exception.Message -replace "`n", " " -replace "`r", " "
                }
            }
            if ($SkipRODC) {
                [Array] $Findings['DomainDomainControllers'][$Domain] = $AllDC | Where-Object { $_.IsReadOnly -eq $false }
                #$Findings[$Domain] = $AllDC | Where-Object { $_.IsReadOnly -eq $false }
            } else {
                [Array] $Findings['DomainDomainControllers'][$Domain] = $AllDC
                #$Findings[$Domain] = $AllDC
            }
            # Building all DCs for whole Forest
            [Array] $Findings['DomainDomainControllers'][$Domain]
        }
        if ($Extended) {
            $Findings['DomainsExtended'] = @{ }
            foreach ($DomainEx in $Findings['Domains']) {
                try {
                    $Findings['DomainsExtended'][$DomainEx] = Get-ADDomain -Server $Findings['QueryServers'][$DomainEx].HostName[0]
                } catch {
                    Write-Warning "Get-WinADForestDetails - Error gathering Domain Information for domain $DomainEx - $($_.Exception.Message)"
                    continue
                }
            }
        }
        # Bring back setting as per default
        if ($TemporaryProgress) {
            $Global:ProgressPreference = $TemporaryProgress
        }

        $Findings
    } else {
        # this takes care of limiting output to only what we requested, but based on prior input
        # this makes sure we ask once for all AD stuff and then subsequent calls just filter out things
        # this should be much faster then asking again and again for stuff from AD
        $Findings = Copy-Dictionary -Dictionary $ExtendedForestInformation
        [Array] $Findings['Domains'] = foreach ($_ in $Findings.Domains) {
            if ($IncludeDomains) {
                if ($_ -in $IncludeDomains) {
                    $_.ToLower()
                }
                # We skip checking for exclusions
                continue
            }
            if ($_ -notin $ExcludeDomains) {
                $_.ToLower()
            }
        }
        # Now that we have Domains we need to remove all DCs that are not from domains we excluded or included
        foreach ($_ in [string[]] $Findings.DomainDomainControllers.Keys) {
            if ($_ -notin $Findings.Domains) {
                $Findings.DomainDomainControllers.Remove($_)
            }
        }
        # Same as above but for query servers
        foreach ($_ in [string[]] $Findings.QueryServers.Keys) {
            if ($_ -notin $Findings.Domains -and $_ -ne 'Forest') {
                $Findings.QueryServers.Remove($_)
            }
        }

        [Array] $Findings['ForestDomainControllers'] = foreach ($Domain in $Findings.Domains) {
            [Array] $AllDC = foreach ($S in $Findings.DomainDomainControllers["$Domain"]) {
                if ($IncludeDomainControllers.Count -gt 0) {
                    If (-not $IncludeDomainControllers[0].Contains('.')) {
                        if ($S.Name -notin $IncludeDomainControllers) {
                            continue
                        }
                    } else {
                        if ($S.HostName -notin $IncludeDomainControllers) {
                            continue
                        }
                    }
                }
                if ($ExcludeDomainControllers.Count -gt 0) {
                    If (-not $ExcludeDomainControllers[0].Contains('.')) {
                        if ($S.Name -in $ExcludeDomainControllers) {
                            continue
                        }
                    } else {
                        if ($S.HostName -in $ExcludeDomainControllers) {
                            continue
                        }
                    }
                }
                $S
            }
            if ($SkipRODC) {
                [Array] $Findings['DomainDomainControllers'][$Domain] = $AllDC | Where-Object { $_.IsReadOnly -eq $false }
            } else {
                [Array] $Findings['DomainDomainControllers'][$Domain] = $AllDC
            }
            # Building all DCs for whole Forest
            [Array] $Findings['DomainDomainControllers'][$Domain]
        }
        $Findings
    }
}

#$F = Get-WinADForestDetails -Forest 'test.evotec.pl'
#$F

#$F.DomainDomainControllers['ad.evotec.xyz'] | Format-Table -AutoSize
#$F

<#
$F = Get-WinADForestDetails -SkipRODC -ExcludeDomainControllers 'AD1.ad.evotec.xyz' #-TestAvailability #-IncludeDomains 'ad.evotec.xyz'
$F | Format-Table -AutoSize

$F.'ad.evotec.xyz' | Format-Table -AutoSize *
$F.'ad.evotec.pl' | Format-Table -AutoSize *

#>