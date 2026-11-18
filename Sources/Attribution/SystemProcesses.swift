// the fixed list of system process names. unknown names count as apps. extend here.
let systemProcessNames: Set<String> = [
    "mDNSResponder", "nsurlsessiond", "apsd", "locationd", "geod", "trustd", "cloudd", "rapportd",
    "identityservices", "kernel_task", "storekitd", "appstored", "amsengagementd", "transparencyd",
    "maild", "TilesService", "ConnectMobile", "watchlistd", "networkserviceproxy", "destinationd",
    "symptomsd", "wifid", "CommCenter", "dataaccessd", "itunescloudd", "passd", "searchpartyd",
    "sharingd", "timed", "assistantd", "akd", "accountsd", "AppleIDAuthAgent", "appleaccountd",
    "familycircled", "findmydeviced", "fmfd", "gamed", "homed", "healthd", "mediaremoted",
    "siriknowledged", "suggestd", "weatherd", "webbookmarksd", "wifianalyticsd",
]

/// the system names plus their 16-character cut forms, built once
let systemProcessLookup: Set<String> = Set(systemProcessNames).union(systemProcessNames.map(ProcessNames.cut))

/// processes that carry the Mac-phone USB link (heartbeatd, lockdownd). used by the deviceLink category
let deviceLinkProcesses: Set<String> = ["heartbeatd", "lockdownd"]
