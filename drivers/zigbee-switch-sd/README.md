## (NEW RELEASE) Version 6.5 for the Edge Beta Driver: Zigbee Switc Mc

## Improvements:

- Added capability for Device Last Hop Metrics Signal, LQI and RSSI. Same as Zigbee Multi Switch Mc

- Added in preferences a setting for restore status after power lost

- As request of @BlackRose67, I added new profile Switch-battery


## (NEW RELEASE) Version 6 of the Edge Beta Driver: Zigbee Switch Mc

## Improvements:

To improve the functions of Timer, which cannot be easily done with the app, I have changed the Random Off-On function to a Timer Mode function, which has the options:

- Inactive: Disables the timer and turns off the device, starting to function as a manual switch

- Random: Alternate on and off randomly, between the maximum and minimum times chosen in Preferences

- Program: Turn on and off with fixed times for On and Off chosen in Preferences

## (NEW RELEASE) Version 5 of the Edge Beta Driver: Zigbee Switch Mc

## Improvements:

At the request of @milandjurovic71 , one of his many good ideas, Add to devices a simulated meter of power and energy consumption.

(I will implement it in a few days in Zigbee Light Multifunction Mc too)

Added Capability PowerMeter:

Displays the rated power entered in preferences, when device is On

The standard graph shows the consumption in each hour or day

Added Capability EnergyMeter:

Displays the energy consumption accumulated during the device’s operating time (On)

The Standard Graph shows the accumulated Energy meter by hour or days of the last month

Added Custom Capability to Reset Energy Meter Accumulated Value:

The switch always gets into On state (blue)

When device is first installed, it displays the installation date.

when you run a Energy reset it displays the current date as the last reset

Added in Preference the setting to enter the Rated Power in W of the load connected to the device:

Power range between 0 w and 4000 w

If 0 w is entered , the power calculation and power and Energy consumption function is disabled. The accumulated values are not deleted.

## (NEW RELEASE) Version 4.0 of Edge Driver Zigbee Switch Mc.

The new version adds:

- Categories set to SmartPlug in all profiles in order to mor option for change Icon from App tool

- Added more Icons in preferences: Tv, Washer, Refrigerator, Air Conditioner, Oven

## (NEW RELEASE) Version 3.0 of Edge Driver Zigbee Switch Mc.

The new version adds:

- Version Info in Device Preferences

## Randon ON-OFF Function so that they can be used in automations to turn on and off randomly together with the Bulbs that already have it.

- Made with a Custom Capability it can be activated and deactivated with automations and scenes.

- The Minimum and Maximum times between which the bulb will randomly turn on and off is set in Preferences and can be set between 0.5 minutes and 25 minutes, depending on the needs of each one.

## How does it work?:

- When the Random On Off functions is activated, a random interval is calculated between the values ​​chosen in preferences.

- When the calculated interval is met, it will turn off or on.

- When the Random function is deactivated, the light also turns off.

- You can create scenes and automations to activate and deactivate the function.

## Preferences for Profile Icon Change Light, Plug, Switch, fan, Camera, Humidifier

## For devices supported see Fingerprints.yml file:

## Supported Devices

129 Zigbee fingerprints.

| Device | Manufacturer | Model | Profile |
|---|---|---|---|
| Lidl Plug | `_TZ3000_kdi2o9m6` | `TS011F` | single-switch-plug |
| Lidl Plug | `_TZ3000_wamqdr3f` | `TS011F` | single-switch-plug |
| Moes Switch | `_TZ3000_zmy1waw6` | `TS011F` | single-switch |
| Samotech Switch | `_TYZB01_iuepbmpv` | `TS0121` | single-switch |
| 3A SMart Switch | `3A SMart Home DE` | `LXN56-LC27LX1.3` | single-switch |
| eWeLink Plug | `eWeLink` | `SA-003-Zigbee` | single-switch-plug |
| NET2GRID Switch | `NET2GRID` | `SP31` | single-switch-plug |
| 3A Smart Switch | `3A Smart Home DE` | `LXN-1S27LX1.0` | single-switch |
| Cloud Even Switch | `_TYZB01_ncutbjdi` | `TS0003` | single-switch |
| Vimar Switch | `Vimar` | `On_Off_Switch_v1.0` | single-switch |
| SONOFF Switch | `SONOFF` | `BASICZBR3` | single-switch |
| SZ  Switch | `SZ` | `Lamp_01` | single-switch |
| IKEA Plug | `IKEA of Sweden` | `TRADFRI control outlet` | single-switch-plug |
| TUYATEC Switch | `TUYATEC-ymxzzux6` | `TS0011` | single-switch |
| TZ3000 Switch | `_TZ3000_3wkqni6o` | `TS0011` | single-switch |
| TUYATEC Switch | `TUYATEC-j5khr9vo` | `TS0011` | single-switch |
| TZ3000 Switch | `_TZ3000_hktqahrq` | `TS0001` | single-switch |
| SONOFF Switch | `SONOFF` | `01MINIZB` | single-switch |
| Switch | `麦克力特` | `55e0fa5cdb144ba3a91aefb87c068cff` | single-switch |
| innr Plug | `innr` | `SP 222` | single-switch-plug |
| Aqara Switch | `LUMI` | `lumi.switch.l0acn1` | single-switch |
| Third Reality Plug | `Third Reality, Inc` | `3RSP019BZ` | single-switch-plug |
| Lidl Plug | `_TZ3000_00mk2xzy` | `TS011F` | single-switch |
| Zemismart Switch | `3A Smart Home DE` | `LXN59-1S7LX1.0` | single-switch |
| FeiBit Switch | `FeiBit` | `FNB56-ZSW01LX2.0` | single-switch |
| LoraTap Switch | `_TZ3000_oiymh3qu` | `TS011F` | single-switch |
| TS0001 Switch | `_TYZB01_phjeraqq` | `TS0001` | single-switch |
| TS0011 Switch | `_TZ3000_fgkrj3bi` | `TS0011` | single-switch |
| Jasco Switch | `Jasco Products` | `43076 Sin` | single-switch |
| TZ3000 Plug | `_TZ3000_5f43h46b` | `TS011F` | single-switch |
| TZ3000 Switch | `_TZ3000_ark8nv4y` | `TS0001` | single-switch |
| eWeLink Switch | `eWeLink` | `SWITCH-ZR02-1` | single-switch-plug |
| Jasco 43076 Switch | `Jasco Products` | `43076` | single-switch |
| TZ3000 Switch | `_TZ3000_yl3zuyaw` | `TS0001` | single-switch |
| TZ3000 Switch | `_TZ3000_qmi1cfuq` | `TS0011` | single-switch |
| TUYATEC Switch | `TUYATEC-dp5y39af` | `TS0001` | single-switch |
| TUYATEC Switch | `_TZ3000_v7gnj3ad` | `TS0001` | single-switch |
| eWeLink Switch | `eWeLink` | `ZB-SW01` | single-switch |
| TZ3000 Switch | `_TYZB01_xfpdrwvc` | `TS0011` | single-switch |
| TZ3000 Switch | `_TZ3000_tygpxwqa` | `TS0001` | single-switch |
| TZ3000 Switch | `_TZ3000_txpirhfq` | `TS0011` | single-switch |
| TS0001 Switch | `_TZ3000_npzfdcof` | `TS0001` | single-switch |
| S31 Lite Switch | `SONOFF` | `S31 Lite zb` | single-switch |
| LEDVANCE Plug | `LEDVANCE` | `PLUG` | single-switch-plug |
| LEDVANCE Plug | `LEDVANCE` | `Plug Z3` | single-switch-plug |
| TS0011 Switch | `_TYZB01_qeqvmvti` | `TS0011` | single-switch |
| TS0011 Switch | `_TZ3000_hhiodade` | `TS0011` | single-switch |
| ASKVADER switch | `IKEA of Sweden` | `ASKVADER on/off switch` | single-switch |
| Third Reality 3RSS009Z | `Third Reality, Inc` | `3RSS009Z` | switch-battery-light |
| TS011F Plug | `_TZ3000_8voyyjng` | `TS011F` | single-switch-plug |
| TS0011 Switch | `_TZ3000_9hpxg80k` | `TS0011` | single-switch |
| Securifi Ltd Switch | `Securifi Ltd.` | (any) | single-switch |
| TZ3000 Plug | `_TZ3000_bkfe0bab` | `TS011F` | single-switch |
| TS0001 Switch | `_TZ3000_tqlv4ug4` | `TS0001` | single-switch |
| ZBMINI-L Switch | `SONOFF` | `ZBMINI-L` | single-switch |
| OSRAM_Plug 01 | `OSRAM` | `Plug 01` | single-switch-plug |
| FeiBit_Plug | `FeiBit` | `FNB56-SKT1JXN1.0` | single-switch-plug |
| TS0001 Switch | `_TZ3000_oysiif07` | `TS0001` | single-switch |
| TS0001 Switch | `_TZ3000_ji4araar` | `TS0011` | single-switch |
| Smart Switch | `_TZ3000_rmjr4ufz` | `TS0001` | single-switch |
| SONOFF Switch | `SONOFF` | `S26R2ZB` | single-switch-plug |
| MLI Switch | `MLI` | `Smart Socket` | single-switch-plug |
| Centralite Outlet | `Centralite Systems` | `4200-C` | single-switch-plug |
| Moes MS-104ZL Switch | `_TZ3000_zzoangmc` | `TS0011` | single-switch |
| TS011F Plug | `_TZ3000_r6buo8ba` | `TS011F` | single-switch-plug |
| PLUG COMPACT EU T | `LEDVANCE` | `PLUG COMPACT EU T` | single-switch-plug |
| Plug Value | `LEDVANCE` | `Plug Value` | single-switch-plug |
| TS0101 Plug | `_TZ3000_pnzfdr9y` | `TS0101` | single-switch-plug |
| TS0001 Plug | `_TZ3000_m0btfbt7` | `TS0001` | single-switch-plug |
| TS011F Plug | `_TZ3000_pmz6mjyu` | `TS011F` | single-switch-plug |
| SONOFF Switch | `SONOFF` | `S40LITE` | single-switch-plug |
| TS0011 Switch | `_TZ3000_ilauzyjm` | `TS0011` | single-switch |
| TS0001 Switch | `_TZ3000_5ng23zjs` | `TS0001` | single-switch |
| TS000F Plug | `_TZ3000_mx3vgyea` | `TS000F` | single-switch-plug |
| LUMI plug | `LUMI` | `lumi.plug` | single-switch-plug |
| TS0001 Switch | `_TZ3000_q6a3tepg` | `TS0001` | single-switch |
| 3A SMart Switch | `3A SMart Home DE` | `LXN56-0S27LX1.3` | single-switch-plug |
| 3A SMart Switch | `3A SMart Home DE` | `LXN-1S27LX1.0` | single-switch |
| TS0001 Switch | `_TZ3000_ajv2vfow` | `TS0001` | single-switch |
| Orvibo Switch | `欧瑞博` | `545df2981b704114945f6df1c780515a` | single-switch |
| Aqara Smart Wall Switch (No Neutral, Single Rocker) | `LUMI` | `lumi.switch.b1laus01` | single-switch |
| TS0101 Switch | `_TZ3000_br3laukf` | `TS0101` | single-switch-plug |
| Philips Hue Plug | `Signify Netherlands B.V.` | `LOM005` | single-switch-plug |
| Smart Switch | `Quirky` | `Smart Switch` | single-light-endpoint2 |
| Interfree 1 Switch | `Interfree` | `XSSW1O` | single-switch |
| Interfree 1 Plug | `Interfree` | `UPSK1O` | single-switch-plug |
| Philips Hue Plug | `Signify Netherlands B.V.` | `LOM010` | single-switch-plug |
| TS0001 Switch | `_TZ3000_0t4zjtia` | `TS0001` | single-switch |
| Lidl Plug | `_TZ3000_upjrsxh1` | `TS011F` | single-switch-plug |
| Third Reality 3RSS007Z | `Third Reality, Inc` | `3RSS007Z` | switch-battery-light |
| Third Reality 3RSS008Z | `Third Reality, Inc` | `3RSS008Z` | switch-battery-light |
| Lidl Plug | `_TZ3000_ynmowqk2` | `TS011F` | single-switch-plug |
| SONOFF Switch | `SONOFF` | `ZBMINIL2` | single-switch |
| Smart Switch | `_TZ3000_jcqs2mrv` | `SM0001` | single-switch |
| LM-SZ1 Switch | `Lumi Vietnam` | `LM-SZ1` | single-switch |
| sengled Plug | `sengled` | `E1C-NB6` | single-switch-plug |
| CentraLite Plug | `CentraLite Systems` | `4256050-ZHAC` | single-switch-plug |
| TS011F Plug | `_TZ3000_2xlvlnez` | `TS011F` | single-switch-plug |
| TS0001 Switch | `_TZ3000_gjrubzje` | `TS0001` | single-switch |
| TS0011 Switch | `_TZ3000_hufg57fw` | `TS0011` | single-switch |
| TS0001 Switch | `_TZ3000_ckorfokt` | `TS0001` | single-switch |
| TS0011 Switch | `_TZ3000_bmzfjnbp` | `TS0011` | single-switch |
| TS0001 Switch | `_TZ3000_46t1rvdu` | `TS0001` | single-switch |
| Fingerbot Plus | `_TZ3210_dse8ogfy` | `TS0001` | switch-battery |
| TS0001 Switch | `_TZ3000_jy3whlzd` | `TS0001` | single-switch |
| TS0012 Switch | `_TZ3000_en6s3mku` | `TS0012` | single-switch |
| TS0001 Switch | `_TZ3000_majwnphg` | `TS0001` | single-switch |
| Fingerbot Plus | `_TZ3210_j4pdtz9v` | `TS0001` | switch-battery |
| TS0001 Switch | `_TZ3000_mantufyr` | `TS0001` | single-switch |
| TS0001 Switch | `_TZ3000_agpdnnyd` | `TS0001` | single-switch |
| innr Plug | `innr` | `OSP 210` | single-switch-plug |
| innr Plug | `innr` | `SP 220` | single-switch-plug |
| BSEED Switch | `_TZ3000_hafsqare` | `TS0011` | single-switch |
| TS0001 Switch | `_TZ3000_zw7yf6yk` | `TS0001` | single-switch |
| eWeLink Switch | `eWeLink` | `SWITCH-ZR03-1` | single-switch |
| TS0001 Switch | `_TZ3000_wijoqjk1` | `TS0001` | single-switch |
| TS0001 Switch | `_TZ3000_bmqxalil` | `TS0001` | single-switch |
| Hej Fingerbot Plus | `_TZ3210_cm9mbpr1` | `TS0001` | switch-battery |
| WL-SW01 Switch 30A | `_TZ3000_jrpdaujd` | `TS0001` | single-switch-plug |
| IKEA TRETAKT Plug | `IKEA of Sweden` | `TRETAKT Smart plug` | single-switch-plug |
| TS0001 Switch | `_TZ3000_y4che4dc` | `TS0001` | single-switch |
| TS0001 Plug | `_TZ3000_fdxihpp7` | `TS0001` | single-switch |
| MHCOZY 16A Switch | `_TZ3218_7fiyo3kv` | `TS000F` | mhcozy-switch |
| BSEED Plug | `_TZ3000_o1jzcxou` | `TS011F` | single-switch-plug |
| Dry Contact Switch | `_TZ3000_hdc8bbha` | `TS000F` | single-switch |
| ZBMicro Switch | `SONOFF` | `ZBMicro` | single-switch |
| Sonoff ZBMINIR2 | `SONOFF` | `ZBMINIR2` | single-switch |
| TS0001 Switch | (any) | `TS0001` | single-switch |
| TS0011 Switch | (any) | `TS0011` | single-switch |
