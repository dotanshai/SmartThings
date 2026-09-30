/**
 *  Xiaomi Mijia Honeywell Natural Gas Detector
 *  Version 0.02
 *
 *  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
 *  in compliance with the License. You may obtain a copy of the License at:
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software distributed under the License is distributed
 *  on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License
 *  for the specific language governing permissions and limitations under the License.
 *
 *  Known issues:
 *	Xiaomi sensors do not seem to respond to refresh requests // workaround... push physical button 1 time for refresh
 *	Inconsistent rendering of user interface text/graphics between iOS and Android devices - This is due to SmartThings, not this device handler
 *	Pairing Xiaomi sensors can be difficult as they were not designed to use with a SmartThings hub, for this one, normally just tap main button 3 times
 *  Natural gas alarm on power-on-reset generates a sequence of clear-alarm-clear-tested-clear alarm statuses in rapid succession, appears to be intentional
 *
 *  Fingerprint Endpoint data:
 *        01 - endpoint id
 *        0104 - profile id
 *        0101 - device id
 *        01 - ignored
 *        07 - number of in clusters
 *        0000 0004 0003 0001 0002 000A 0500 - inClusters
 *        02 - number of out clusters
 *        0019 000A - outClusters
 *        manufacturer "LUMI" - must match manufacturer field in fingerprint
 *        model "lumi.sensor_natgas" - must match model in 
 */
 
import physicalgraph.zigbee.clusters.iaszone.ZoneStatus
import physicalgraph.zigbee.zcl.DataType

metadata {
	definition (name: "Xiaomi Mijia Honeywell Natural Gas Detector", namespace: "mroszko", author: "mroszko") {
		capability "Health Check"
		capability "Sensor"
        
		command "enrollResponse"
		command "resetClear"
		command "resetDetected"
        
        attribute "natgas", "enum", ["detected","clear","tested"]
        
		attribute "lastTested", "String"
		attribute "lastTestedDate", "Date"
		attribute "lastCheckinDate", "Date"
		attribute "lastCheckin", "string"
		attribute "lastNatGas", "String"
		attribute "lastNatGasDate", "Date"		
        
        fingerprint endpointId: "01", profileID: "0104", deviceID: "0101", inClusters: "0000 0004 0003 0001 0002 000A 0500", outClusters: "0019 000A", manufacturer: "LUMI", model: "lumi.sensor_natgas", deviceJoinName: "Xiaomi Honeywell Natural Gas Detector"
	}

	preferences {
		//Date & Time Config
		input description: "", type: "paragraph", element: "paragraph", title: "DATE & CLOCK"    
		input name: "dateformat", type: "enum", title: "Set Date Format\nUS (MDY) - UK (DMY) - Other (YMD)", description: "Date Format", options:["US","UK","Other"]
		input name: "clockformat", type: "bool", title: "Use 24 hour clock?"
	}
    
	// simulator metadata
	simulator {
		// Not Applicable to Thing Device
	}

	tiles {
		multiAttributeTile(name:"natgas", type: "lighting", width: 6, height: 4) {
			tileAttribute ("device.natgas", key: "PRIMARY_CONTROL") {
           			attributeState( "clear", label:'CLEAR', icon:"st.alarm.smoke.clear", backgroundColor:"#ffffff")
					attributeState( "tested", label:"TEST", icon:"st.alarm.smoke.test", backgroundColor:"#e86d13")
					attributeState( "detected", label:'SMOKE', icon:"st.alarm.smoke.smoke", backgroundColor:"#ed0920")   
 			}
            tileAttribute("device.lastNatGas", key: "SECONDARY_CONTROL") {
                		attributeState "default", label:'Natural gas last detected:\n ${currentValue}'
			}	
		}
        
		valueTile("lastTested", "device.lastTested", inactiveLabel: false, decoration: "flat", width: 4, height: 1) {
            		state "default", label:'Last Tested:\n ${currentValue}'
		}
        
		valueTile("lastCheckin", "device.lastCheckin", inactiveLabel: false, decoration:"flat", width: 4, height: 1) {
            		state "lastCheckin", label:'Last Event:\n ${currentValue}'
        }
            
		main "natgas"
		details(["natgas","lastTested", "lastCheckin"])
	}
}

// Parse incoming device messages to generate events
def parse(String description) {
	log.debug "${device.displayName}: Parsing description: ${description}"
    
	// Determine current time and date in the user-selected date format and clock style
	def now = formatDate()    
	def nowDate = new Date(now).getTime()
    
	// Any report - test, gas, clear in a lastCheckin event and update to Last Checkin tile
	// However, only a non-parseable report results in lastCheckin being displayed in events log
	sendEvent(name: "lastCheckin", value: now, displayed: false)
	sendEvent(name: "lastCheckinDate", value: nowDate, displayed: false)
    
	def map = zigbee.getEvent(description)
	if(!map) {
        if (description?.startsWith('zone status')) {
            map = parseZoneStatusMessage(description)
            if (map.value == "detected") {
                sendEvent(name: "lastNatGas", value: now, displayed: false)
                sendEvent(name: "lastNatGasDate", value: nowDate, displayed: false)
            } else if (map.value == "tested") {
				sendEvent(name: "lastTested", value: now, displayed: false)
				sendEvent(name: "lastTestedDate", value: nowDate, displayed: false)
			}	
        } else {
			map = parseAttrMessage(description)
        }
    }
    else {
		log.debug "${device.displayName}: was unable to parse ${description}"
		sendEvent(name: "lastCheckin", value: now) 
	}
    
    log.debug "${device.displayName}: Parse returned ${map}"
	def result = map ? createEvent(map) : [:]

	if (description?.startsWith('enroll request')) {
		List cmds = zigbee.enrollResponse()
		log.debug "enroll response: ${cmds}"
		result = cmds?.collect { new physicalgraph.device.HubAction(it) }
	}
	return result
}

private Map parseAttrMessage(description) {
	def descMap = zigbee.parseDescriptionAsMap(description)
	def map = [:]
    
    log.debug "Got attr message ${descMap}"
    
	return map
}

// Parse the IAS messages
private Map parseZoneStatusMessage(String description) {
	ZoneStatus zs = zigbee.parseZoneStatus(description)
    
	def result = [
		name: 'natgas',
		value: value,
		descriptionText: ''
	]
    
    //alarm 2 - test alarm
    //alarm 1 - natgas alarm

    if (zs.isAlarm2Set()) {
        result.value = "tested"
        result.descriptionText = "${device.displayName} has been tested"
    } else if (zs.isAlarm1Set()) {
        result.value = "detected"
        result.descriptionText = "${device.displayName} has detected natural gas"
    } else if (!zs.isAlarm1Set() && !zs.isAlarm2Set()) {
        result.value = "clear"
        result.descriptionText = "${device.displayName} is all clear"
    }
    return result
}


def formatDate() {
	def correctedTimezone = ""
	def timeString = clockformat ? "HH:mm:ss" : "h:mm:ss aa"

	// If user's hub timezone is not set, display error messages in log and events log, and set timezone to GMT to avoid errors
	if (!(location.timeZone)) {
		correctedTimezone = TimeZone.getTimeZone("GMT")
		log.error "${device.displayName}: Time Zone not set, so GMT was used. Please set up your location in the SmartThings mobile app."
		sendEvent(name: "error", value: "", descriptionText: "ERROR: Time Zone not set, so GMT was used. Please set up your location in the SmartThings mobile app.")
	} else {
		correctedTimezone = location.timeZone
	}
	if (dateformat == "US" || dateformat == "" || dateformat == null) {
		return new Date().format("EEE MMM dd yyyy ${timeString}", correctedTimezone)
	} else if (dateformat == "UK") {
		return new Date().format("EEE dd MMM yyyy ${timeString}", correctedTimezone)
	} else {
		return new Date().format("EEE yyyy MMM dd ${timeString}", correctedTimezone)
	}
}

def resetClear() {
	sendEvent(name:"natgas", value:"clear")
}

def resetDetected() {
	sendEvent(name:"natgas", value:"detected")
}
