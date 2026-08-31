-- fetch_library_identity.applescript
-- Returns a generation-fenced, columnar snapshot of canonical Music database identity.

use framework "Foundation"
use scripting additions

on run argv
    try
        if (count of argv) < 1 then error "Library path is required"
        set libraryPath to my resolve_path(item 1 of argv)
        set generation to my library_token(libraryPath)
        set columnSeparator to ASCII character 28
        set itemSeparator to ASCII character 29

        tell application "Music"
            set trackReference to a reference to (every track of library playlist 1)
            set snapshotCount to count of trackReference
            set databaseIDs to id of trackReference
            set artistValues to artist of trackReference
            set albumArtistValues to album artist of trackReference
        end tell

        my require_count(databaseIDs, snapshotCount, "database IDs")
        my require_count(artistValues, snapshotCount, "artists")
        my require_count(albumArtistValues, snapshotCount, "album artists")
        if my library_token(libraryPath) is not generation then return "RETRY:GENERATION"

        return "IDENTITY" & columnSeparator & snapshotCount & columnSeparator & generation & columnSeparator & ¬
            my join_text(databaseIDs, itemSeparator) & columnSeparator & ¬
            my json_text(artistValues) & columnSeparator & ¬
            my json_text(albumArtistValues)
    on error errorMessage
        return "ERROR:" & errorMessage
    end try
end run

on require_count(values, expectedCount, columnName)
    if (count of values) is not expectedCount then
        error "Identity " & columnName & " count does not match Music library count"
    end if
end require_count

on resolve_path(configuredPath)
    set homePath to POSIX path of (path to home folder)
    if configuredPath is "~" then return text 1 thru -2 of homePath
    if configuredPath is "~/" then return homePath
    if configuredPath is "${HOME}" then return text 1 thru -2 of homePath
    if configuredPath is "${HOME}/" then return homePath
    if configuredPath starts with "${HOME}/" then return homePath & text 9 thru -1 of configuredPath
    if configuredPath starts with "~/" then return homePath & text 3 thru -1 of configuredPath
    return configuredPath
end resolve_path

on library_token(libraryPath)
    set databasePath to libraryPath & "/Library.musicdb"
    set fileManager to current application's NSFileManager's defaultManager()
    set databaseInfo to fileManager's attributesOfItemAtPath:databasePath |error|:(missing value)
    if databaseInfo is missing value then
        error "LIBRARY_DB_NOT_FOUND: Music library database not found at " & databasePath
    end if
    set modifiedAt to databaseInfo's objectForKey:(current application's NSFileModificationDate)
    set databaseSize to databaseInfo's objectForKey:(current application's NSFileSize)
    return ((modifiedAt's timeIntervalSince1970()) as text) & "-" & (databaseSize as text)
end library_token

on json_text(values)
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:values options:0 |error|:(missing value)
    if jsonData is missing value then error "Could not serialize identity text column"
    set jsonText to current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)
    if jsonText is missing value then error "Could not encode identity text column"
    return jsonText as text
end json_text

on join_text(values, separator)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joinedText to values as text
    set AppleScript's text item delimiters to oldDelimiters
    return joinedText
end join_text
