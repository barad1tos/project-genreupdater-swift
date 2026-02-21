# App Store Listing — Genre Updater

## Basic Info

- **Name:** Genre Updater
- **Subtitle:** Fix genres and years in Music
- **Category:** Music
- **Secondary Category:** Utilities
- **Age Rating:** 4+
- **Price:** Free (with Pro subscription)

## Description (max 4000 chars)

Genre Updater automatically fixes missing and incorrect
genres and release years in your Apple Music library.

**The Problem**
Your Music library has tracks with wrong genres, missing
years, or inconsistent metadata. Manually fixing thousands
of tracks is impractical.

**The Solution**
Genre Updater scans your library, looks up correct metadata
from MusicBrainz, Discogs, and Apple Music, and applies
fixes directly to Music.app. Everything happens on your Mac
with no data collection.

**Key Features**

- Automatic genre detection from multiple music databases
- Release year lookup with confidence scoring
- Batch processing for entire library or selected tracks
- Preview changes before applying them
- One-click undo for any change
- Smart album and artist matching with fuzzy logic
- Handles compilations, remasters, and live albums
- Checkpoint and resume for large library processing

**How It Works**

1. Grant access to your Music library
2. Select tracks or scan your entire library
3. Review proposed changes with confidence scores
4. Apply changes or skip individual tracks
5. Undo any change at any time

**Free Tier**
Process up to 500 tracks at no cost — no time limit,
no expiration.

**Week Pass — $1.99**
Unlock unlimited tracks for 7 days. Perfect for a
one-time library cleanup.

**Pro Subscription**
Unlimited tracks, batch processing, CSV export, and
priority API access. $4.99/month or $29.99/year.

**Privacy First**
No data collection. No analytics. No tracking. All
processing happens locally on your Mac. Only artist and
album names are sent to music databases for lookups.

## Keywords (max 100 chars)

genre,music,metadata,year,tag,fix,organize,library,album,cleanup

## What's New — Version 1.0

Initial release:
- Genre detection from 3 music databases
- Release year lookup with confidence scoring
- Batch processing with progress tracking
- Change preview and one-click undo
- Free tier: 500 tracks (lifetime)

## In-App Purchases

| Name | Type | Price |
|------|------|-------|
| Week Pass | Non-renewing | $1.99 / 7 days |
| Pro Monthly | Auto-renewable | $4.99/mo |
| Pro Annual | Auto-renewable | $29.99/yr |

## Review Notes

This app uses NSUserAppleScriptTask to write metadata to
Music.app. MusicKit is read-only and provides no write API.
AppleScript via scripting-targets is the only supported
mechanism for modifying track properties from a sandboxed
app. See the attached justification document for details.

A StoreKit sandbox test account is available for testing
the subscription flow.

## Screenshots Required

- 1 screenshot: Library scan in progress
- 1 screenshot: Change preview with confidence badges
- 1 screenshot: Batch processing results
- 1 screenshot: Settings / subscription view
- Sizes: 1280x800 (13-inch), 2880x1800 (16-inch Retina)
