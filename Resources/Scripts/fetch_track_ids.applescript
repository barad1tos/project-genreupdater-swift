-- fetch_track_ids.applescript
-- Lightweight script that returns track IDs in bounded batches.
-- Used by Smart Delta to detect new/removed tracks without fetching full metadata.

on run argv
    try
        if (count of argv) < 2 then error "Batch offset and limit are required"
        set batchOffset to (item 1 of argv) as integer
        set batchLimit to (item 2 of argv) as integer
        if batchOffset < 1 then error "Batch offset must be at least 1"
        if batchLimit < 1 then error "Batch limit must be at least 1"

        tell application "Music"
            set libraryCount to (count of tracks of library playlist 1)
            if libraryCount = 0 then return "BATCH:0:0:"
            if batchOffset > libraryCount then return "BATCH:" & libraryCount & ":" & libraryCount & ":"

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

        return "BATCH:" & endIndex & ":" & libraryCount & ":" & my join_text(trackIDs, ",")
    on error errorMessage
        return "ERROR:" & errorMessage
    end try
end run

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
