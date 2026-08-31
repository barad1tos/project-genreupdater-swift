-- fetch_track_ids.applescript
-- Returns one generation-fenced census of Music database track IDs.
-- MusicKit does not expose this identity domain, so mirror membership uses this read-only primitive.

use framework "Foundation"
use scripting additions

on run argv
    try
        if (count of argv) < 1 then error "Library path is required"
        set libraryPath to my resolve_path(item 1 of argv)
        set generation to my library_token(libraryPath)

        tell application "Music"
            set libraryCount to (count of tracks of library playlist 1)
            set idList to id of every track of library playlist 1
            set censusCount to count of idList
            if censusCount is not libraryCount then error "Track ID census count does not match Music library count"
        end tell

        if my library_token(libraryPath) is not generation then return "RETRY:GENERATION"
        return "CENSUS:" & censusCount & ":" & generation & ":" & my join_text(idList, ",")
    on error errorMessage
        return "ERROR:" & errorMessage
    end try
end run

on resolve_path(configuredPath)
    -- Resolve the real home outside the app container; Swift cannot do this in the MAS sandbox.
    set homePath to POSIX path of (path to home folder)
    if configuredPath is "~" then
        return text 1 thru -2 of homePath
    end if
    if configuredPath is "~/" then return homePath
    if configuredPath is "${HOME}" then
        return text 1 thru -2 of homePath
    end if
    if configuredPath is "${HOME}/" then return homePath
    if configuredPath starts with "${HOME}/" then
        return homePath & text 9 thru -1 of configuredPath
    end if
    if configuredPath starts with "~/" then
        return homePath & text 3 thru -1 of configuredPath
    end if
    return configuredPath
end resolve_path

on library_token(libraryPath)
    -- This disk token is a conservative, best-effort fence for mutations between Music.app reads.
    -- It is opaque, locale-dependent, and only compared for equality within one scan.
    set databasePath to libraryPath & "/Library.musicdb"
    set fileManager to current application's NSFileManager's defaultManager()
    set databaseInfo to fileManager's attributesOfItemAtPath:databasePath |error|:(missing value)
    if databaseInfo is missing value then
        -- LIBRARY_DB_NOT_FOUND is part of the Swift wire contract.
        error "LIBRARY_DB_NOT_FOUND: Music library database not found at " & databasePath
    end if
    set modifiedAt to databaseInfo's objectForKey:(current application's NSFileModificationDate)
    set databaseSize to databaseInfo's objectForKey:(current application's NSFileSize)
    return ((modifiedAt's timeIntervalSince1970()) as text) & "-" & (databaseSize as text)
end library_token

on join_text(values, separator)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joinedText to values as text
    set AppleScript's text item delimiters to oldDelimiters
    return joinedText
end join_text
