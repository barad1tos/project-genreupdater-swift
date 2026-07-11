-- fetch_track_ids.applescript
-- Lightweight script that returns track IDs in bounded batches.
-- Used by Smart Delta to detect new/removed tracks without fetching full metadata.

on run argv
    try
        if (count of argv) < 3 then error "Batch offset, limit, and library path are required"
        set batchOffset to (item 1 of argv) as integer
        set batchLimit to (item 2 of argv) as integer
        set libraryPath to my resolve_path(item 3 of argv)
        if batchOffset < 1 then error "Batch offset must be at least 1"
        if batchLimit < 1 then error "Batch limit must be at least 1"
        set generation to my library_token(libraryPath)

        tell application "Music"
            set libraryCount to (count of tracks of library playlist 1)
            if libraryCount = 0 then return "BATCH:0:0:" & generation & ":"
            if batchOffset > libraryCount then
                return "BATCH:" & libraryCount & ":" & libraryCount & ":" & generation & ":"
            end if

            set endIndex to batchOffset + batchLimit - 1
            if endIndex > libraryCount then set endIndex to libraryCount
            set trackRef to a reference to (tracks batchOffset thru endIndex of library playlist 1)
            set trackCount to count of trackRef
            set idList to id of trackRef
            set trackIDs to {}

            repeat with index from 1 to trackCount
                set trackID to my item_or_missing(idList, index)
                if trackID is missing value then
                    error "Missing track ID at library index " & ((batchOffset + index - 1) as text)
                end if
                set end of trackIDs to trackID
            end repeat
        end tell

        return "BATCH:" & endIndex & ":" & libraryCount & ":" & generation & ":" & my join_text(trackIDs, ",")
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
    set databasePath to libraryPath & "/Library.musicdb"
    try
        set databaseInfo to info for POSIX file databasePath
    on error
        -- LIBRARY_DB_NOT_FOUND is part of the Swift wire contract.
        error "LIBRARY_DB_NOT_FOUND: Music library database not found at " & databasePath
    end try
    set modifiedAt to modification date of databaseInfo
    set epoch to current date
    set year of epoch to 1970
    set month of epoch to January
    set day of epoch to 1
    set time of epoch to 0
    return ((modifiedAt - epoch) as text) & "-" & (size of databaseInfo as text)
end library_token

on item_or_missing(values, position)
    try
        if class of values is list then
            if (count of values) >= position then return item position of values
        else if position = 1 then
            return values
        end if
    on error
        return missing value
    end try
    return missing value
end item_or_missing

on join_text(values, separator)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joinedText to values as text
    set AppleScript's text item delimiters to oldDelimiters
    return joinedText
end join_text
