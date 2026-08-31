-- fetch_scope_metadata.applescript
-- Returns generation-fenced processing metadata as parallel property columns.

use framework "Foundation"
use scripting additions

on run argv
    try
        if (count of argv) < 1 then error "Library path is required"
        set libraryPath to my resolve_path(item 1 of argv)
        if (count of argv) > 1 then
            set selectedArtist to item 2 of argv
        else
            set selectedArtist to ""
        end if
        set generation to my library_token(libraryPath)
        set columnSeparator to ASCII character 28
        set itemSeparator to ASCII character 29

        tell application "Music"
            if selectedArtist is "" then
                set trackReference to a reference to (every track of library playlist 1)
            else
                set trackReference to a reference to (every track of library playlist 1 whose ¬
                    (artist is selectedArtist) or (album artist is selectedArtist))
            end if

            set snapshotCount to count of trackReference
            set databaseIDs to id of trackReference
            set nameValues to name of trackReference
            set artistValues to artist of trackReference
            set albumArtistValues to album artist of trackReference
            set albumValues to album of trackReference
            set genreValues to genre of trackReference
            set rawDateAddedValues to date added of trackReference
            set rawModifiedValues to modification date of trackReference
            set rawStatusValues to cloud status of trackReference
            set yearValues to year of trackReference
            set rawReleaseDateValues to release date of trackReference
        end tell

        set columns to {databaseIDs, nameValues, artistValues, albumArtistValues, albumValues, genreValues, ¬
            rawDateAddedValues, rawModifiedValues, rawStatusValues, yearValues, rawReleaseDateValues}
        repeat with columnIndex from 1 to count of columns
            my require_count(item columnIndex of columns, snapshotCount, columnIndex)
        end repeat
        if my library_token(libraryPath) is not generation then return "RETRY:GENERATION"

        set responseParts to {"METADATA", snapshotCount as text, generation, ¬
            my join_text(databaseIDs, itemSeparator), ¬
            my json_text(nameValues), ¬
            my json_text(artistValues), ¬
            my json_text(albumArtistValues), ¬
            my json_text(albumValues), ¬
            my json_text(genreValues), ¬
            my join_timestamps(rawDateAddedValues, itemSeparator), ¬
            my join_timestamps(rawModifiedValues, itemSeparator), ¬
            my join_text(rawStatusValues, itemSeparator), ¬
            my join_text(yearValues, itemSeparator), ¬
            my join_timestamps(rawReleaseDateValues, itemSeparator)}
        return my join_text(responseParts, columnSeparator)
    on error errorMessage
        return "ERROR:" & errorMessage
    end try
end run

on require_count(values, expectedCount, columnIndex)
    if (count of values) is not expectedCount then
        error "Metadata column " & columnIndex & " count does not match selected track count"
    end if
end require_count

on join_timestamps(values, separator)
    if (count of values) is 0 then return ""
    set cocoaDates to current application's NSArray's arrayWithArray:values
    set timestamps to cocoaDates's valueForKey:"timeIntervalSince1970"
    set timestampTexts to timestamps's valueForKey:"stringValue"
    set joinedText to timestampTexts's componentsJoinedByString:(separator & "unix:")
    return "unix:" & (joinedText as text)
end join_timestamps

on json_text(values)
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:values options:0 |error|:(missing value)
    if jsonData is missing value then error "Could not serialize metadata text column"
    set jsonText to current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)
    if jsonText is missing value then error "Could not encode metadata text column"
    return jsonText as text
end json_text

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

on join_text(values, separator)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joinedText to values as text
    set AppleScript's text item delimiters to oldDelimiters
    return joinedText
end join_text
