import QtQuick
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../"

// =============================================================================
// MovieWidget.qml — watchlist & review-lookup widget
// =============================================================================
// This widget does not stream, embed, mirror-check, or link to any pirated /
// unauthorized video source. It only ever talks to legitimate, public
// metadata APIs (Cinemeta, OMDb) and opens real pages — imdb.com,
// myanimelist.net, themoviedb.org, netflix.com, hulu.com — in your browser.
// It does three things:
//
//   1. SEARCH  — look up a movie or show; clicking a result opens the View
//      Info picker so you can jump to reviews/ratings on whichever site.
//   2. MY LIST — one grid you build yourself for instant access without
//      searching. Add either a Movie or a Series from the Add panel.
//   3. REVIEWS — each entry in My List shows a rating + short description
//      right below it, pulled from free metadata APIs.
//
// There are exactly five link destinations anywhere in this file — IMDb,
// MyAnimeList, TMDB, Netflix, Hulu — all hardcoded, all in the View Info
// picker. Not a configurable/swappable source list: there is no "add a
// site" input anywhere in the UI. See the LINK OPENERS section below for
// why that's deliberate.
//
// Everything below is grouped into commented sections so it's easy to find
// and change the bit you want.
// =============================================================================

Item {
    id: window
    focus: true

    Caching { id: paths }
    readonly property string moviesCache: paths.getCacheDir("movies")

    Scaler {
        id: scaler
        currentWidth: Screen.width
    }
    function s(val) {
        return scaler.s(val);
    }

    MatugenColors { id: _theme }
    readonly property color base: _theme.base
    readonly property color crust: _theme.crust
    readonly property color mantle: _theme.mantle
    readonly property color text: _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color mauve: _theme.mauve || "#cba6f7"
    readonly property color blue: _theme.blue || "#89b4fa"
    readonly property color green: _theme.green || "#a6e3a1"
    readonly property color red: _theme.red || "#f38ba8"
    readonly property color yellow: _theme.yellow || "#f9e2af"
    readonly property color pink: _theme.pink || "#f5c2e7"

    // How many list entries can be shown per row before wrapping — tweak to
    // taste depending on how wide this widget is on your screen.
    readonly property int posterColumns: 5

    // =========================================================================
    // STATE
    // =========================================================================
    property string topView: "search"      // "search" | "mylist"
    property string searchScope: "movie"   // "movie" | "tv"        (search tab)
    property bool isSearchingNetwork: false

    // series drill-down (reached by clicking a TV result in search)
    property string seriesView: ""         // "" or the series' imdbId
    property string seriesTitle: ""
    property string seriesPoster: ""
    property string seriesDescription: ""
    property string seriesRating: ""
    property int currentSeason: 1
    property bool isLoadingSeries: false
    property var seriesEpisodesBySeason: ({})

    // add-to-my-list panel
    property bool addPanelOpen: false
    property string addPanelCategory: "movie"      // "movie" | "series" — which Cinemeta catalog to search
    property bool addPanelSearching: false
    property bool addPanelSearched: false
    property bool manualFieldsOpen: false
    property bool manualTypeIsSeries: false

    property bool stateRestored: false
    property bool episodePickerOpen: false
    property string pickerMode: "episodes"   // "episodes" | "seasons" — which picker panel to show
    property bool sitePickerOpen: false      // the "View Info" site picker
    property string pickerImdbId: ""         // which title the picker is currently showing
    property string pickerTitle: ""

    // My List: one merged list of movies + series, with a live text filter
    property string listFilterText: ""
    property string lastAddCategory: "movie"   // remembers your last Add-panel choice

    // =========================================================================
    // TIMERS
    // =========================================================================
    property real introPhase: 0
    NumberAnimation on introPhase {
        id: introPhaseAnim
        from: 0; to: 1; duration: 800; easing.type: Easing.OutQuart; running: true
    }

    Timer {
        id: focusTimer
        interval: 50; running: true; repeat: false
        onTriggered: {
            if (window.topView === "search" && window.seriesView === "") searchInput.forceActiveFocus()
            else window.forceActiveFocus()
        }
    }

    Timer {
        id: searchDebounceTimer
        interval: 400; repeat: false
        onTriggered: {
            if (searchInput.text.trim() !== "") doSearch(searchInput.text)
        }
    }

    // Defensive: if a request never calls back (dropped connection, DNS hiccup)
    // this makes sure a spinner never gets stuck on forever.
    Timer {
        id: safetyLoadingTimer
        interval: 12000
        running: window.isSearchingNetwork || window.isLoadingSeries || window.addPanelSearching
        repeat: false
        onTriggered: {
            window.isSearchingNetwork = false
            window.isLoadingSeries = false
            window.addPanelSearching = false
        }
    }

    Timer { id: seasonFadeTimer; interval: 30; repeat: false; onTriggered: window.seasonSwitching = false }
    property bool seasonSwitching: false

    // =========================================================================
    // LIFECYCLE
    // =========================================================================

    Component.onCompleted: {
        readManualListProc.running = true
        readUiStateProc.running = true
        readRecentSearchesProc.running = true
        loadDashboardIfNeeded()
    }
    Connections {
        target: window
        function onVisibleChanged() {
            if (window.visible) {
                introPhaseAnim.restart()
                if (window.topView === "search" && window.seriesView === "") focusTimer.restart()
            } else {
                saveUiState()
            }
        }
    }

    Keys.onPressed: (event) => {
        if (window.sitePickerOpen) {
            if (event.key === Qt.Key_Escape) { closeSitePicker(); event.accepted = true }
        } else if (window.episodePickerOpen) {
            if (event.key === Qt.Key_Escape) { closeEpisodePicker(); event.accepted = true }
        } else if (window.addPanelOpen) {
            if (event.key === Qt.Key_Escape) { closeAddPanel(); event.accepted = true }
        } else if (window.topView === "search" && window.seriesView !== "") {
            if (event.key === Qt.Key_Escape) { backToSearchResults(); event.accepted = true }
        } else if (event.key === Qt.Key_Escape) {
            saveUiState()
            Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "close"])
            event.accepted = true
        }
    }

    // =========================================================================
    // DATA MODELS
    // =========================================================================
    ListModel { id: searchResultsModel }      // imdbId, title, year, type, poster, rating
    ListModel { id: seasonModel }             // seasonNum, epCount
    ListModel { id: episodeModel }            // epNum, epTitle, hasRealTitle
    ListModel { id: addPanelResultsModel }    // unified schema, see makeCandidateEntry()
    ListModel { id: myListModel }             // the one persisted list — movies + series, see makeListEntry()
    ListModel { id: filteredListModel }       // myListModel filtered by listFilterText
    ListModel { id: popularMoviesModel }
    ListModel { id: popularTvModel }
    ListModel { id: recentSearchesModel }     // { query }

    // Fixed field sets so QML's ListModel never infers a different role set
    // between appends (it locks roles in from the first row per-model).
    function makeEntryKey() {
        return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
    }
    function makeSearchResult(f) {
        return { imdbId: f.imdbId || "", title: f.title || "Unknown", year: f.year || "N/A",
                 type: f.type || "movie", poster: f.poster || "", rating: f.rating || "" }
    }
    function makeCandidateEntry(f) {
        return { imdbId: f.imdbId || "", title: f.title || "Unknown", year: f.year || "",
                 type: f.type || "", poster: f.poster || "", rating: f.rating || "" }
    }
    // The one schema for My List entries — movies and series together.
    function makeListEntry(f) {
        return { key: f.key || makeEntryKey(), imdbId: f.imdbId || "", title: f.title || "Unknown", year: f.year || "",
                 type: f.type || "movie", poster: f.poster || "", rating: f.rating || "",
                 description: f.description || "", addedAt: f.addedAt || Date.now() }
    }

    function myListModelToArray() {
        let arr = []
        for (let i = 0; i < myListModel.count; i++) {
            let o = myListModel.get(i)
            arr.push({ key: o.key, imdbId: o.imdbId, title: o.title, year: o.year, type: o.type,
                       poster: o.poster, rating: o.rating, description: o.description, addedAt: o.addedAt })
        }
        return arr
    }

    function findEntryIndexByKey(model, key) {
        for (let i = 0; i < model.count; i++) {
            if (model.get(i).key === key) return i
        }
        return -1
    }

    function applyListFilter() {
        let q = window.listFilterText.trim().toLowerCase()
        let sorted = myListModelToArray().sort(function(a, b) { return b.addedAt - a.addedAt })
        filteredListModel.clear()
        for (let i = 0; i < sorted.length; i++) {
            let o = sorted[i]
            if (q === "" || o.title.toLowerCase().indexOf(q) !== -1) filteredListModel.append(makeListEntry(o))
        }
    }

    // =========================================================================
    // CACHE I/O — same read/write plumbing style as the rest of this rice
    // =========================================================================
    function saveJsonToCache(filename, dataObj) {
        // split/join instead of a regex — same effect (escape every single
        // quote for safe embedding inside the shell's single-quoted string)
        let jsStr = JSON.stringify(dataObj).split("'").join("'\\''")
        Quickshell.execDetached(["bash", "-c", "echo '" + jsStr + "' > " + window.moviesCache + "/" + filename])
    }

    function saveManualList() {
        saveJsonToCache("qs_manual_list.json", { items: myListModelToArray() })
    }

    function saveUiState() {
        saveJsonToCache("qs_ui_state.json", {
            topView: window.topView, searchScope: window.searchScope, lastAddCategory: window.lastAddCategory
        })
    }

    function saveRecentSearches() {
        let arr = []
        for (let i = 0; i < recentSearchesModel.count; i++) arr.push(recentSearchesModel.get(i).query)
        saveJsonToCache("qs_recent_searches.json", arr)
    }

    Process {
        id: readManualListProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_manual_list.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let parsed = JSON.parse(data.trim())
                    // New format is {items: [...]}. Older saves used
                    // {anime: [...], notAnime: [...]} — migrate the
                    // notAnime half forward and drop anime, since that
                    // category no longer exists.
                    let itemsArr = parsed.items || parsed.notAnime || []
                    myListModel.clear()
                    for (let i = 0; i < itemsArr.length; i++) myListModel.append(makeListEntry(itemsArr[i]))
                } catch (e) { /* first run — no list yet, that's fine */ }
                applyListFilter()
            }
        }
    }

    Process {
        id: readUiStateProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_ui_state.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let s = JSON.parse(data.trim())
                    if (s.topView) window.topView = s.topView
                    if (s.searchScope) window.searchScope = s.searchScope
                    if (s.lastAddCategory === "movie" || s.lastAddCategory === "series") window.lastAddCategory = s.lastAddCategory
                    else if (s.listTab === "anime") window.lastAddCategory = "series"
                } catch (e) { /* first run */ }
                window.stateRestored = true
            }
        }
    }

    Process {
        id: readRecentSearchesProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_recent_searches.json 2>/dev/null || echo '[]'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let arr = JSON.parse(data.trim())
                    recentSearchesModel.clear()
                    for (let i = 0; i < arr.length; i++) recentSearchesModel.append({ query: arr[i] })
                } catch (e) { /* first run — no history yet */ }
            }
        }
    }

    // =========================================================================
    // SEARCH — Cinemeta (Stremio's open metadata catalog: titles, posters,
    // ratings, synopses). This is a metadata database, same idea as TMDB —
    // it does not host or link to video streams.
    // =========================================================================
    function doSearch(query) {
        let q = query.trim()
        let expectedScope = window.searchScope
        let typeStr = expectedScope === "movie" ? "movie" : "series"
        if (q === "") { searchResultsModel.clear(); window.isSearchingNetwork = false; return }
        window.isSearchingNetwork = true
        searchResultsModel.clear()
        searchCinemetaRaw(q, typeStr, function(results) {
            if (window.searchScope !== expectedScope) return
            window.isSearchingNetwork = false
            for (let i = 0; i < results.length; i++) searchResultsModel.append(makeSearchResult(results[i]))
            if (results.length > 0) addRecentSearch(q)
        })
    }

    function addRecentSearch(query) {
        let q = query.trim()
        if (q === "") return
        for (let i = recentSearchesModel.count - 1; i >= 0; i--) {
            if (recentSearchesModel.get(i).query.toLowerCase() === q.toLowerCase()) recentSearchesModel.remove(i)
        }
        recentSearchesModel.insert(0, { query: q })
        while (recentSearchesModel.count > 8) recentSearchesModel.remove(recentSearchesModel.count - 1)
        saveRecentSearches()
    }

    // Popular/trending catalogs — same Cinemeta metadata source as search,
    // just without a search term. Fetched once per session and cached in
    // memory; tap the section again after reopening if you want it fresher.
    function fetchPopular(typeStr, targetModel) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://v3-cinemeta.strem.io/catalog/" + typeStr + "/top.json")
        xhr.timeout = 8000
        xhr.onerror = function() {}
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    let list = (res && res.metas) ? res.metas.slice(0, 12) : []
                    targetModel.clear()
                    for (let i = 0; i < list.length; i++) {
                        let item = list[i]
                        if (!item.id) continue
                        targetModel.append(makeSearchResult({
                            imdbId: item.id, title: item.name, year: item.releaseInfo,
                            type: item.type === "series" ? "tv" : "movie",
                            poster: item.poster || item.background || "",
                            rating: (item.imdbRating && item.imdbRating !== "N/A") ? item.imdbRating : ""
                        }))
                    }
                } catch (e) {}
            }
        }
        xhr.send()
    }

    function loadDashboardIfNeeded() {
        if (popularMoviesModel.count === 0) fetchPopular("movie", popularMoviesModel)
        if (popularTvModel.count === 0) fetchPopular("series", popularTvModel)
    }

    function openResult(item) {
        if (item.type === "movie") {
            openSitePicker(item.imdbId, item.title)
        } else {
            openSeriesDetail(item.imdbId, item.title, item.poster)
        }
    }

    function fetchCinemetaDetail(imdbId, typeStr, callback) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://v3-cinemeta.strem.io/meta/" + typeStr + "/" + imdbId + ".json")
        xhr.timeout = 7000
        xhr.onerror = function() { callback(null) }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    if (res && res.meta) { callback(res.meta); return }
                } catch (e) {}
            }
            callback(null)
        }
        xhr.send()
    }

    // =========================================================================
    // SERIES DRILL-DOWN — season/episode browser, purely from Cinemeta
    // metadata. No "watch" action anywhere; every exit point opens a real
    // IMDb page.
    // =========================================================================
    function openSeriesDetail(imdbId, title, poster) {
        window.topView = "search"
        window.seriesView = imdbId
        window.seriesTitle = title
        window.seriesPoster = poster
        window.seriesDescription = ""
        window.seriesRating = ""
        window.isLoadingSeries = true
        seasonModel.clear()
        episodeModel.clear()
        fetchCinemetaDetail(imdbId, "series", function(meta) {
            window.isLoadingSeries = false
            if (!meta) return
            window.seriesDescription = meta.description || meta.synopsis || ""
            window.seriesRating = (meta.imdbRating && meta.imdbRating !== "N/A") ? meta.imdbRating : ""
            if (meta.poster && window.seriesPoster === "") window.seriesPoster = meta.poster
            if (meta.videos) {
                let seasonsMap = {}
                for (let i = 0; i < meta.videos.length; i++) {
                    let v = meta.videos[i]
                    if (!v.season) continue
                    if (!seasonsMap[v.season]) seasonsMap[v.season] = []
                    let epTitle = v.name || v.title || ""
                    let lower = epTitle.toLowerCase().trim()
                    let isGeneric = lower === "" || lower === ("episode " + v.episode) || lower === ("s" + v.season + "e" + v.episode)
                    seasonsMap[v.season].push({ ep: v.episode, title: isGeneric ? ("Episode " + v.episode) : epTitle, hasRealTitle: !isGeneric })
                }
                let seasonKeys = Object.keys(seasonsMap).map(Number).sort(function(a, b) { return a - b })
                for (let i = 0; i < seasonKeys.length; i++) seasonModel.append({ seasonNum: seasonKeys[i], epCount: seasonsMap[seasonKeys[i]].length })
                window.seriesEpisodesBySeason = seasonsMap
                let firstSeason = seasonKeys.length > 0 ? seasonKeys[0] : 1
                window.currentSeason = firstSeason
                updateEpisodesForSeason(firstSeason)
            }
        })
    }

    function updateEpisodesForSeason(seasonNum) {
        window.currentSeason = seasonNum
        window.seasonSwitching = true
        episodeModel.clear()
        let eps = window.seriesEpisodesBySeason[seasonNum]
        if (eps) {
            eps.sort(function(a, b) { return a.ep - b.ep })
            for (let i = 0; i < eps.length; i++) {
                episodeModel.append({ epNum: eps[i].ep, epTitle: eps[i].title, hasRealTitle: eps[i].hasRealTitle })
            }
        }
        seasonFadeTimer.restart()
    }

    function backToSearchResults() {
        window.seriesView = ""
        saveUiState()
        Qt.callLater(function() { if (window.topView === "search") searchInput.forceActiveFocus() })
    }

    function openEpisodePicker() {
        window.pickerMode = "episodes"
        window.episodePickerOpen = true
    }

    function openSeasonPicker() {
        window.pickerMode = "seasons"
        window.episodePickerOpen = true
    }

    function openSitePicker(imdbId, title) {
        window.pickerImdbId = imdbId
        window.pickerTitle = title
        window.sitePickerOpen = true
    }

    function closeSitePicker() {
        window.sitePickerOpen = false
    }

    function closeEpisodePicker() {
        window.episodePickerOpen = false
    }

    // =========================================================================
    // LINK OPENERS — the only "action" buttons in this widget. Every one of
    // these opens a real page on imdb.com, myanimelist.net, themoviedb.org,
    // netflix.com, or hulu.com in your default browser via xdg-open. There
    // are exactly five named destinations here, all hardcoded — not a
    // configurable/extensible list — see the note above openTmdb for why.
    // =========================================================================
    function openImdb(imdbId) {
        if (!imdbId) return
        Quickshell.execDetached(["xdg-open", "https://www.imdb.com/title/" + imdbId + "/"])
    }

    function openImdbSeasonPage(imdbId, season) {
        if (!imdbId) return
        Quickshell.execDetached(["xdg-open", "https://www.imdb.com/title/" + imdbId + "/episodes/?season=" + season])
    }

    // True only when an OMDb key is configured. OMDb is the only free,
    // documented way to resolve series+season+episode to that specific
    // episode's own IMDb id — Cinemeta's episode entries don't carry one.
    // Surfaced as a property so the UI can be upfront about which mode
    // you're in, rather than clicking an episode and silently landing on
    // the season page with no explanation.

    function openImdbEpisodeSmart(seriesImdbId, season, epNum) {
        
       //if (!window.hasEpisodeDeepLinks) { openImdbSeasonPage(seriesImdbId, season); return }
        Quickshell.execDetached(["xdg-open", "https://player.imdb.su/embed/tv/" + seriesImdbId + "/" + season + "/" + epNum])
    }
    function openImdbMovie(seriesImdbId) {
        
       //if (!window.hasEpisodeDeepLinks) { openImdbSeasonPage(seriesImdbId, season); return }
        Quickshell.execDetached(["xdg-open", "https://player.imdb.su/embed/movie/" + seriesImdbId])
    }
    // Title-based, not id-based on purpose: MyAnimeList has no public,
    // keyless way to resolve an IMDb id to a MAL id, and the last attempt
    // at id-matching (via Jikan) was exactly what didn't work reliably.
    // A plain search URL can't get an id-match wrong because it isn't
    // matching anything — it just hands the browser a query and MAL's own
    // search does the rest.
    function openMalSearch(title) {
        if (!title) return
        Quickshell.execDetached(["xdg-open", "https://myanimelist.net/anime.php?q=" + encodeURIComponent(title)])
    }

    // A third, hardcoded, legitimate destination (themoviedb.org) — not a
    // switchable/extensible source list. TMDB resolves an IMDb id directly
    // via its own /find endpoint, so this needs no availability checking.

    // Netflix and Hulu, same title-search approach as MyAnimeList — no id
    // matching to get wrong. Both require you to already be logged in to
    // that service in your browser; if you're not, the link just lands you
    // on their sign-in page instead of results.
    function openNetflixSearch(title) {
        if (!title) return
        Quickshell.execDetached(["xdg-open", "https://www.netflix.com/search?q=" + encodeURIComponent(title)])
    }
    // =========================================================================
    // MY LIST — add / pick / save / remove / refresh. This is the only place
    // that writes to qs_manual_list.json.
    // =========================================================================
    function searchCinemetaRaw(query, typeStr, callback) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://v3-cinemeta.strem.io/catalog/" + typeStr + "/top/search=" + encodeURIComponent(query) + ".json")
        xhr.timeout = 8000
        xhr.onerror = function() { callback([]) }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    let list = (res && res.metas) ? res.metas : []
                    let out = []
                    for (let i = 0; i < list.length; i++) {
                        let item = list[i]
                        if (!item.id) continue
                        out.push({
                            imdbId: item.id, title: item.name || "Unknown", year: item.releaseInfo || "",
                            type: item.type === "series" ? "tv" : "movie",
                            poster: item.poster || item.background || "",
                            rating: (item.imdbRating && item.imdbRating !== "N/A") ? item.imdbRating : ""
                        })
                    }
                    callback(out)
                    return
                } catch (e) {}
            }
            callback([])
        }
        xhr.send()
    }

    function openAddPanel() {
        window.addPanelCategory = window.lastAddCategory
        window.manualTypeIsSeries = window.lastAddCategory === "series"
        addPanelResultsModel.clear()
        window.addPanelSearching = false
        window.addPanelSearched = false
        window.manualFieldsOpen = false
        addTitleInput.text = ""
        manualTitleInput.text = ""
        manualYearInput.text = ""
        manualPosterInput.text = ""
        manualIdInput.text = ""
        manualNotesInput.text = ""
        window.addPanelOpen = true
        Qt.callLater(function() { addTitleInput.forceActiveFocus() })
    }

    function closeAddPanel() {
        window.addPanelOpen = false
        if (window.topView === "search" && window.seriesView === "") Qt.callLater(function() { searchInput.forceActiveFocus() })
    }

    // Searches ONLY the selected category's Cinemeta catalog — a series
    // search returns series, a movie search returns movies, no merging.
    function runAddSearch() {
        let q = addTitleInput.text.trim()
        if (q === "") return
        window.addPanelSearching = true
        window.addPanelSearched = false
        addPanelResultsModel.clear()
        searchCinemetaRaw(q, window.addPanelCategory, function(results) {
            window.addPanelSearching = false
            window.addPanelSearched = true
            for (let i = 0; i < results.length; i++) addPanelResultsModel.append(makeCandidateEntry(results[i]))
        })
    }

    function pickAddCandidate(candidate) {
        window.addPanelSearching = true
        let typeStr = candidate.type === "tv" ? "series" : "movie"
        fetchCinemetaDetail(candidate.imdbId, typeStr, function(meta) {
            let description = meta ? (meta.description || meta.synopsis || "") : ""
            let rating = candidate.rating
            if (meta && meta.imdbRating && meta.imdbRating !== "N/A") rating = meta.imdbRating
            function finalizeAdd(finalDescription, finalRating) {
                myListModel.append(makeListEntry({
                    imdbId: candidate.imdbId, title: candidate.title, year: candidate.year,
                    type: candidate.type, poster: candidate.poster, rating: finalRating,
                    description: finalDescription, addedAt: Date.now()
                }))
                window.addPanelSearching = false
                saveManualList()
                applyListFilter()
                closeAddPanel()
            }
                finalizeAdd(description, rating)
        })
    }

    function saveManualFieldsEntry() {
        let title = manualTitleInput.text.trim()
        if (title === "") return
        myListModel.append(makeListEntry({
            imdbId: manualIdInput.text.trim(), title: title, year: manualYearInput.text.trim(),
            type: window.manualTypeIsSeries ? "tv" : "movie", poster: manualPosterInput.text.trim(),
            description: manualNotesInput.text.trim(), addedAt: Date.now()
        }))
        saveManualList()
        applyListFilter()
        closeAddPanel()
    }

    // key identifies the entry in myListModel. My List's grid shows a
    // derived, re-sorted, filtered copy (filteredListModel), so an index
    // into THAT isn't safe to write back with — the key is stable.
    function removeEntry(key) {
        let idx = findEntryIndexByKey(myListModel, key)
        if (idx === -1) return
        myListModel.remove(idx)
        saveManualList()
        applyListFilter()
    }

    function refreshEntry(key) {
        let idx = findEntryIndexByKey(myListModel, key)
        if (idx === -1) return
        let item = myListModel.get(idx)
        if (!item.imdbId) return
            let typeStr = item.type === "tv" ? "series" : "movie"
            fetchCinemetaDetail(item.imdbId, typeStr, function(meta) {
                if (!meta) return
                let freshIdx = findEntryIndexByKey(myListModel, key)
                if (freshIdx === -1) return
                let cur = myListModel.get(freshIdx)
                myListModel.set(freshIdx, makeListEntry({
                    key: key, imdbId: cur.imdbId, title: cur.title, year: cur.year, type: cur.type,
                    poster: meta.poster || cur.poster,
                    rating: (meta.imdbRating && meta.imdbRating !== "N/A") ? meta.imdbRating : cur.rating,
                    description: meta.description || meta.synopsis || cur.description,
                    addedAt: cur.addedAt
                }))
                saveManualList()
                applyListFilter()
            })
    }

    function candidateSubtitle(item) {
        let parts = []
        if (item.year !== "") parts.push(item.year)
        parts.push(item.type === "tv" ? "Series" : "Movie")
        if (item.rating !== "") parts.push("\u2B50 " + item.rating)
        return parts.join("   \u00B7   ")
    }

    // =========================================================================
    // REUSABLE UI PIECES
    // =========================================================================
    component ActionButton: Rectangle {
        id: btnRoot
        property string label: ""
        property color accent: window.surface1
        property color labelColor: window.text
        property bool filled: false
        signal clicked()
        implicitHeight: window.s(40)
        radius: window.s(10)
        opacity: enabled ? 1 : 0.5
        color: filled ? accent : (btnMouse.containsMouse ? window.surface2 : window.surface1)
        border.color: filled ? accent : window.surface2
        border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
            anchors.centerIn: parent
            text: btnRoot.label
            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13)
            color: btnRoot.filled ? window.crust : btnRoot.labelColor
        }
        MouseArea { id: btnMouse; anchors.fill: parent; hoverEnabled: true; onClicked: btnRoot.clicked() }
    }

    component IconButton: Rectangle {
        id: iconRoot
        property string glyph: "\u00D7"
        property color glyphColor: window.subtext0
        property color hoverColor: window.surface2
        signal clicked()
        implicitWidth: window.s(28); implicitHeight: window.s(28)
        radius: window.s(8)
        color: iconMouse.containsMouse ? hoverColor : "transparent"
        Behavior on color { ColorAnimation { duration: 150 } }
        Text { anchors.centerIn: parent; text: iconRoot.glyph; color: iconRoot.glyphColor; font.pixelSize: window.s(13); font.family: "JetBrains Mono" }
        MouseArea { id: iconMouse; anchors.fill: parent; hoverEnabled: true; onClicked: iconRoot.clicked() }
    }

    component StyledInput: TextField {
        id: fieldRoot
        Layout.fillWidth: true
        Layout.preferredHeight: window.s(40)
        background: Rectangle {
            color: fieldRoot.activeFocus ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6) : window.surface0
            radius: window.s(10)
            border.color: fieldRoot.activeFocus ? window.surface2 : "transparent"
            border.width: 1
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        color: window.text
        font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
        leftPadding: window.s(12)
        placeholderTextColor: window.subtext0
        verticalAlignment: TextInput.AlignVCenter
    }

    component SearchResultCard: Item {
        id: cardRoot
        width: GridView.view.cellWidth
        height: GridView.view.cellHeight
        property bool isHovered: cardMouse.containsMouse
        Rectangle {
            anchors.fill: parent; anchors.margins: window.s(6); radius: window.s(10); color: "transparent"
            ColumnLayout {
                anchors.fill: parent; spacing: window.s(6)
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(8); color: window.crust; clip: true
                    Image {
                        id: cardPoster
                        anchors.fill: parent
                        source: model.poster !== "" ? model.poster : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true; smooth: true; cache: true
                        visible: status === Image.Ready
                    }
                    Rectangle {
                        anchors.fill: parent; color: window.surface0; radius: window.s(8)
                        visible: model.poster === "" || cardPoster.status === Image.Error
                        Column {
                            anchors.centerIn: parent; width: parent.width - window.s(10); spacing: window.s(4)
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: model.type === "tv" ? "\uD83D\uDCFA" : "\uD83C\uDFAC"; font.pixelSize: window.s(20) }
                            Text { width: parent.width; text: model.title; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; maximumLineCount: 3; elide: Text.ElideRight }
                        }
                    }
                    Rectangle {
                        visible: model.rating !== ""
                        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: window.s(6)
                        radius: window.s(6); color: Qt.rgba(0, 0, 0, 0.65)
                        width: ratingText.width + window.s(10); height: window.s(20)
                        Text { id: ratingText; anchors.centerIn: parent; text: "\u2B50 " + model.rating; color: window.yellow; font.pixelSize: window.s(10); font.family: "JetBrains Mono"; font.weight: Font.Bold }
                    }
                    Rectangle {
                        anchors.fill: parent; radius: window.s(8)
                        color: model.type === "tv" ? window.blue : window.mauve
                        opacity: cardRoot.isHovered ? 0.22 : 0
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                    }
                }
                Text {
                    Layout.fillWidth: true; text: model.title
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                    color: window.text; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter; lineHeight: 1.1
                }
                Text {
                    Layout.fillWidth: true; text: model.year !== "N/A" ? model.year : ""
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.surface2
                    horizontalAlignment: Text.AlignHCenter; visible: text !== ""
                }
            }
            MouseArea {
                id: cardMouse; anchors.fill: parent; hoverEnabled: true
                onClicked: openResult({ imdbId: model.imdbId, title: model.title, poster: model.poster, type: model.type })
            }
        }
    }

    component PopularCard: Item {
        id: popRoot
        width: window.s(105); height: window.s(190)
        property bool isHovered: popMouse.containsMouse
        ColumnLayout {
            anchors.fill: parent; spacing: window.s(6)
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: window.s(148)
                radius: window.s(9); color: window.crust; clip: true
                Image {
                    id: popPoster
                    anchors.fill: parent
                    source: model.poster !== "" ? model.poster : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; smooth: true; cache: true
                    visible: status === Image.Ready
                }
                Text {
                    anchors.centerIn: parent
                    visible: model.poster === "" || popPoster.status === Image.Error
                    text: model.type === "tv" ? "\uD83D\uDCFA" : "\uD83C\uDFAC"; font.pixelSize: window.s(18)
                }
                Rectangle {
                    visible: model.rating !== ""
                    anchors.top: parent.top; anchors.right: parent.right; anchors.margins: window.s(5)
                    radius: window.s(5); color: Qt.rgba(0, 0, 0, 0.65)
                    width: popRatingText.width + window.s(8); height: window.s(16)
                    Text { id: popRatingText; anchors.centerIn: parent; text: "\u2B50 " + model.rating; color: window.yellow; font.pixelSize: window.s(9); font.family: "JetBrains Mono"; font.weight: Font.Bold }
                }
                Rectangle {
                    anchors.fill: parent; radius: window.s(9)
                    color: model.type === "tv" ? window.blue : window.mauve
                    opacity: popRoot.isHovered ? 0.22 : 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }
            }
            Text {
                Layout.fillWidth: true; text: model.title
                font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                color: window.text; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            }
        }
        MouseArea {
            id: popMouse; anchors.fill: parent; hoverEnabled: true
            onClicked: openResult({ imdbId: model.imdbId, title: model.title, poster: model.poster, type: model.type })
        }
    }

    component RecentSearchChip: Rectangle {
        id: rsChip
        width: rsLabel.width + window.s(24); height: window.s(32); radius: window.s(9)
        color: rsMouse.containsMouse ? window.surface1 : window.surface0
        border.color: window.surface1; border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
            id: rsLabel; anchors.centerIn: parent
            text: model.query
            font.family: "JetBrains Mono"; font.pixelSize: window.s(12); color: window.text
        }
        MouseArea {
            id: rsMouse; anchors.fill: parent; hoverEnabled: true
            onClicked: { searchInput.text = model.query; doSearch(model.query) }
        }
    }

    component ManualEntryCard: Rectangle {
        id: cardRoot
        width: GridView.view.cellWidth
        height: GridView.view.cellHeight
        radius: window.s(12)
        color: cardMouse.containsMouse ? window.surface1 : window.surface0
        border.color: window.surface1; border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }

        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                if (model.type === "tv") openSeriesDetail(model.imdbId, model.title, model.poster)
                else openImdbMovie(model.imdbId)
            }
        }

        ColumnLayout {
            anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(6)
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: width * 1.45
                radius: window.s(9); color: window.crust; clip: true
                Image {
                    id: cardPoster
                    anchors.fill: parent
                    source: model.poster !== "" ? model.poster : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; smooth: true; cache: true
                    visible: status === Image.Ready
                }
                Text {
                    anchors.centerIn: parent
                    visible: model.poster === "" || cardPoster.status === Image.Error
                    text: model.type === "tv" ? "\uD83D\uDCFA" : "\uD83C\uDFAC"
                    font.pixelSize: window.s(18)
                }
                Rectangle {
                    visible: model.rating !== ""
                    anchors.top: parent.top; anchors.right: parent.right; anchors.margins: window.s(5)
                    radius: window.s(5); color: Qt.rgba(0, 0, 0, 0.65)
                    width: cardRatingText.width + window.s(8); height: window.s(16)
                    Text {
                        id: cardRatingText; anchors.centerIn: parent
                        text: "\u2B50 " + model.rating
                        color: window.yellow; font.pixelSize: window.s(9); font.family: "JetBrains Mono"; font.weight: Font.Bold
                    }
                }
                Row {
                    visible: cardMouse.containsMouse
                    anchors.top: parent.top; anchors.left: parent.left; anchors.margins: window.s(5)
                    spacing: window.s(4)
                    IconButton {
                        width: window.s(22); height: window.s(22)
                        glyph: "\u27F3"; glyphColor: "#ffffff"
                        onClicked: refreshEntry(model.key)
                    }
                    IconButton {
                        width: window.s(22); height: window.s(22)
                        glyph: "\u2715"; glyphColor: "#ffffff"
                        hoverColor: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.55)
                        onClicked: removeEntry(model.key)
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                text: model.title
                font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                color: window.text; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter; lineHeight: 1.05
            }
            Text {
                Layout.fillWidth: true
                visible: model.year !== ""
                text: model.year
                font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    component CandidateRow: Rectangle {
        id: candRoot
        width: ListView.view.width
        height: window.s(64)
        radius: window.s(10)
        color: candMouse.containsMouse ? window.surface1 : window.surface0
        border.color: window.surface1; border.width: 1
        Behavior on color { ColorAnimation { duration: 120 } }
        RowLayout {
            anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(10)
            Rectangle {
                Layout.preferredWidth: window.s(40); Layout.fillHeight: true
                radius: window.s(6); color: window.crust; clip: true
                Image {
                    anchors.fill: parent
                    source: model.poster !== "" ? model.poster : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true; smooth: true; visible: status === Image.Ready
                }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: window.s(2)
                Text {
                    Layout.fillWidth: true; text: model.title
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13)
                    color: window.text; elide: Text.ElideRight
                }
                Text {
                    text: candidateSubtitle(model)
                    color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                }
            }
        }
        MouseArea { id: candMouse; anchors.fill: parent; hoverEnabled: true; onClicked: pickAddCandidate(model) }
    }

    component SeasonChip: Rectangle {
        id: chipRoot
        property bool isActive: window.currentSeason === model.seasonNum
        width: chipLabel.width + window.s(24); height: window.s(36); radius: window.s(10)
        color: isActive ? window.blue : window.surface0
        border.color: isActive ? window.blue : window.surface1; border.width: 1
        Behavior on color { ColorAnimation { duration: 200 } }
        Text {
            id: chipLabel; anchors.centerIn: parent
            text: "S" + model.seasonNum
            font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: chipRoot.isActive ? Font.Bold : Font.Medium
            color: chipRoot.isActive ? window.crust : window.text
        }
        MouseArea {
            anchors.fill: parent
            onClicked: { if (window.currentSeason !== model.seasonNum) updateEpisodesForSeason(model.seasonNum) }
        }
    }

    component EpisodeRow: Rectangle {
        id: epRoot
        width: ListView.view.width; height: window.s(54); radius: window.s(10)
        color: epMouse.containsMouse ? window.surface0 : "transparent"
        border.color: epMouse.containsMouse ? window.surface1 : "transparent"; border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }
        RowLayout {
            anchors.fill: parent; anchors.margins: window.s(10); spacing: window.s(12)
            Rectangle {
                Layout.preferredWidth: window.s(34); Layout.preferredHeight: window.s(34); radius: window.s(8)
                color: epMouse.containsMouse ? window.blue : window.surface1
                Behavior on color { ColorAnimation { duration: 150 } }
                Text { anchors.centerIn: parent; text: model.epNum; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(12); color: epMouse.containsMouse ? window.crust : window.subtext0 }
            }
            Text {
                Layout.fillWidth: true; text: model.epTitle
                font.family: "JetBrains Mono"; font.pixelSize: model.hasRealTitle ? window.s(13) : window.s(12)
                color: model.hasRealTitle ? window.text : window.subtext0
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: epMouse; anchors.fill: parent; hoverEnabled: true
            onClicked: {
                openImdbEpisodeSmart(window.seriesView, window.currentSeason, model.epNum)
                closeEpisodePicker()
            }
        }
    }

    component SitePickerRow: Rectangle {
        id: spRoot
        property string label: ""
        property string sub: ""
        property color accent: window.blue
        signal clicked()
        implicitHeight: window.s(52); radius: window.s(10)
        color: spMouse.containsMouse ? window.surface1 : window.surface0
        border.color: window.surface1; border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }
        RowLayout {
            anchors.fill: parent; anchors.margins: window.s(10); spacing: window.s(10)
            Rectangle { Layout.preferredWidth: window.s(8); Layout.preferredHeight: window.s(8); radius: window.s(4); color: spRoot.accent }
            ColumnLayout {
                Layout.fillWidth: true; spacing: window.s(1)
                Text { text: spRoot.label; color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13) }
                Text { text: spRoot.sub; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(10) }
            }
            Text { text: "\u2197"; color: window.subtext0; font.pixelSize: window.s(13) }
        }
        MouseArea { id: spMouse; anchors.fill: parent; hoverEnabled: true; onClicked: spRoot.clicked() }
    }

    component SeasonRow: Rectangle {
        id: seasonRowRoot
        width: ListView.view.width; height: window.s(54); radius: window.s(10)
        color: seasonRowMouse.containsMouse ? window.surface0 : "transparent"
        border.color: seasonRowMouse.containsMouse ? window.surface1 : "transparent"; border.width: 1
        Behavior on color { ColorAnimation { duration: 150 } }
        RowLayout {
            anchors.fill: parent; anchors.margins: window.s(10); spacing: window.s(12)
            Rectangle {
                Layout.preferredWidth: window.s(34); Layout.preferredHeight: window.s(34); radius: window.s(8)
                color: seasonRowMouse.containsMouse ? window.blue : window.surface1
                Behavior on color { ColorAnimation { duration: 150 } }
                Text { anchors.centerIn: parent; text: model.seasonNum; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(12); color: seasonRowMouse.containsMouse ? window.crust : window.subtext0 }
            }
            Text {
                Layout.fillWidth: true; text: "Season " + model.seasonNum
                font.family: "JetBrains Mono"; font.pixelSize: window.s(13); color: window.text
            }
            Text {
                visible: model.epCount > 0
                text: model.epCount + (model.epCount === 1 ? " episode" : " episodes")
                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
            }
            Text {
                text: "IMDb \u2197"; color: window.blue; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
            }
        }
        MouseArea {
            id: seasonRowMouse; anchors.fill: parent; hoverEnabled: true
            onClicked: {
                closeEpisodePicker()
                openImdbSeasonPage(window.seriesView, model.seasonNum)
            }
        }
    }

    // =========================================================================
    // LAYOUT
    // =========================================================================
    Rectangle {
        id: mainBg
        width: parent.width; height: parent.height
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        radius: window.s(14)
        color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.95)
        border.color: Qt.rgba(window.text.r, window.text.g, window.text.b, 0.08)
        border.width: 1
        clip: true
        transform: Translate { y: (1 - window.introPhase) * window.s(50) }
        opacity: window.introPhase

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- TOP MODE TABS ----
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: window.s(58); color: "transparent"
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: window.surface1 }
                RowLayout {
                    anchors.fill: parent; anchors.margins: window.s(10); spacing: window.s(8)
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(10)
                        color: window.topView === "search" ? window.surface1 : (searchTabMouse.containsMouse ? window.surface0 : "transparent")
                        Behavior on color { ColorAnimation { duration: 150 } }
                        RowLayout {
                            anchors.centerIn: parent; spacing: window.s(6)
                            Text { text: "\uD83D\uDD0D"; font.pixelSize: window.s(15) }
                            Text {
                                text: "Search"
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
                                font.weight: window.topView === "search" ? Font.Bold : Font.Medium
                                color: window.topView === "search" ? window.text : window.subtext0
                            }
                        }
                        MouseArea { id: searchTabMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { window.topView = "search"; saveUiState() } }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(10)
                        color: window.topView === "mylist" ? window.surface1 : (listTabMouse.containsMouse ? window.surface0 : "transparent")
                        Behavior on color { ColorAnimation { duration: 150 } }
                        RowLayout {
                            anchors.centerIn: parent; spacing: window.s(6)
                            Text { text: "\uD83D\uDCCB"; font.pixelSize: window.s(15) }
                            Text {
                                text: "My List"
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
                                font.weight: window.topView === "mylist" ? Font.Bold : Font.Medium
                                color: window.topView === "mylist" ? window.text : window.subtext0
                            }
                        }
                        MouseArea { id: listTabMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { window.topView = "mylist"; saveUiState() } }
                    }
                }
            }

            // ---- CONTENT ----
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true

                // === SEARCH RESULTS ===
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    visible: window.topView === "search" && window.seriesView === ""

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(96); color: "transparent"
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(10)
                            Rectangle {
                                Layout.preferredWidth: window.s(180); Layout.preferredHeight: window.s(34); radius: window.s(9); color: window.surface0
                                Rectangle {
                                    width: parent.width / 2 - window.s(4); height: parent.height - window.s(8)
                                    y: window.s(4); radius: window.s(7)
                                    color: window.searchScope === "movie" ? window.mauve : window.blue
                                    x: window.searchScope === "movie" ? window.s(4) : parent.width / 2
                                    Behavior on x { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                                    Behavior on color { ColorAnimation { duration: 250 } }
                                }
                                RowLayout {
                                    anchors.fill: parent; spacing: 0
                                    MouseArea {
                                        Layout.fillWidth: true; Layout.fillHeight: true
                                        onClicked: { window.searchScope = "movie"; if (searchInput.text.trim() !== "") doSearch(searchInput.text) }
                                        Text { anchors.centerIn: parent; text: "Movies"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: window.searchScope === "movie" ? Font.Bold : Font.Medium; color: window.searchScope === "movie" ? window.crust : window.text }
                                    }
                                    MouseArea {
                                        Layout.fillWidth: true; Layout.fillHeight: true
                                        onClicked: { window.searchScope = "tv"; if (searchInput.text.trim() !== "") doSearch(searchInput.text) }
                                        Text { anchors.centerIn: parent; text: "TV Shows"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: window.searchScope === "tv" ? Font.Bold : Font.Medium; color: window.searchScope === "tv" ? window.crust : window.text }
                                    }
                                }
                            }
                            StyledInput {
                                id: searchInput
                                placeholderText: "Search movies or TV shows\u2026"
                                onTextChanged: {
                                    if (text.trim() === "") { searchResultsModel.clear(); window.isSearchingNetwork = false; searchDebounceTimer.stop() }
                                    else searchDebounceTimer.restart()
                                }
                                Keys.onTabPressed: { window.searchScope = window.searchScope === "movie" ? "tv" : "movie"; if (text.trim() !== "") doSearch(text); event.accepted = true }
                                Keys.onReturnPressed: { if (text.trim() !== "") doSearch(text); event.accepted = true }
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true

                        Flickable {
                            anchors.fill: parent
                            visible: searchInput.text.trim() === ""
                            clip: true; contentWidth: width; contentHeight: dashboardCol.implicitHeight
                            ScrollBar.vertical: ScrollBar { active: true; contentItem: Rectangle { radius: window.s(2); color: window.surface2 } }
                            ColumnLayout {
                                id: dashboardCol
                                width: parent.width; spacing: window.s(18)

                                ColumnLayout {
                                    Layout.fillWidth: true; Layout.topMargin: window.s(14); spacing: window.s(8)
                                    visible: recentSearchesModel.count > 0
                                    Text { text: "Recent Searches"; leftPadding: window.s(15); color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13) }
                                    Flow {
                                        Layout.fillWidth: true; Layout.leftMargin: window.s(15); Layout.rightMargin: window.s(15)
                                        spacing: window.s(8)
                                        Repeater {
                                            model: recentSearchesModel
                                            delegate: RecentSearchChip {}
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true; Layout.topMargin: recentSearchesModel.count > 0 ? 0 : window.s(14); spacing: window.s(8)
                                    Text { text: "Popular Movies"; leftPadding: window.s(15); color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13) }
                                    ListView {
                                        Layout.fillWidth: true; Layout.preferredHeight: window.s(190)
                                        orientation: ListView.Horizontal; clip: true
                                        leftMargin: window.s(15); rightMargin: window.s(15); spacing: window.s(10)
                                        model: popularMoviesModel
                                        delegate: PopularCard {}
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true; Layout.bottomMargin: window.s(14); spacing: window.s(8)
                                    Text { text: "Popular TV Shows"; leftPadding: window.s(15); color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13) }
                                    ListView {
                                        Layout.fillWidth: true; Layout.preferredHeight: window.s(190)
                                        orientation: ListView.Horizontal; clip: true
                                        leftMargin: window.s(15); rightMargin: window.s(15); spacing: window.s(10)
                                        model: popularTvModel
                                        delegate: PopularCard {}
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: window.isSearchingNetwork
                            text: "Searching\u2026"
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !window.isSearchingNetwork && searchInput.text.trim() !== "" && searchResultsModel.count === 0
                            text: "No results"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                        }

                        GridView {
                            id: searchGrid
                            anchors.fill: parent; anchors.margins: window.s(15)
                            visible: searchResultsModel.count > 0 && !window.isSearchingNetwork
                            model: searchResultsModel
                            cellWidth: Math.floor(width / window.posterColumns); cellHeight: cellWidth * 1.5 + window.s(52)
                            boundsBehavior: Flickable.StopAtBounds; clip: true
                            ScrollBar.vertical: ScrollBar { active: true; contentItem: Rectangle { radius: window.s(2); color: window.surface2 } }
                            delegate: SearchResultCard {}
                        }
                    }
                }

                // === SERIES DETAIL ===
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(24); spacing: window.s(14)
                    visible: window.topView === "search" && window.seriesView !== ""

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: window.s(10)
                        spacing: window.s(18)
                        Rectangle {
                            Layout.preferredWidth: window.s(140); Layout.preferredHeight: window.s(200)
                            radius: window.s(12); color: window.crust; clip: true
                            Image {
                                id: seriesPosterImg
                                anchors.fill: parent
                                source: window.seriesPoster !== "" ? window.seriesPoster : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; smooth: true; cache: true
                                visible: status === Image.Ready
                            }
                            Rectangle {
                                anchors.fill: parent; color: window.surface0; radius: window.s(12)
                                visible: window.seriesPoster === "" || seriesPosterImg.status === Image.Error
                                Text { anchors.centerIn: parent; width: parent.width - window.s(10); text: window.seriesTitle; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter }
                            }
                        }
                        ColumnLayout {
                            Layout.preferredWidth: window.s(260); Layout.fillHeight: true; spacing: window.s(8)
                            Text {
                                Layout.fillWidth: true; text: window.seriesTitle
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(17); font.weight: Font.Bold
                                color: window.text; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                            }
                            Text {
                                visible: window.seriesRating !== ""
                                text: "\u2B50 " + window.seriesRating
                                color: window.yellow; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold
                            }
                            Flickable {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(window.s(90), seriesDescText.implicitHeight + window.s(6))
                                visible: window.seriesDescription !== ""
                                clip: true; contentHeight: seriesDescText.implicitHeight
                                ScrollBar.vertical: ScrollBar { contentItem: Rectangle { radius: window.s(2); color: window.surface2; implicitWidth: window.s(3) } }
                                Text {
                                    id: seriesDescText
                                    width: parent.width - window.s(6)
                                    text: window.seriesDescription
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                    color: window.subtext0; wrapMode: Text.WordWrap; lineHeight: 1.4
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        visible: window.isLoadingSeries
                        text: "Loading\u2026"
                        color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                    }

                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: window.s(280)
                        spacing: window.s(10)
                        ActionButton { Layout.fillWidth: true; label: "View Info"; filled: true; accent: window.blue; onClicked: openSitePicker(window.seriesView, window.seriesTitle) }
                        ActionButton { Layout.fillWidth: true; label: "Episode List"; onClicked: openEpisodePicker() }
                        ActionButton { Layout.fillWidth: true; label: "Season List"; onClicked: openSeasonPicker() }
                    }

                    Item { Layout.fillHeight: true }

                    ActionButton { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: window.s(140); label: "\u2190 Back"; onClicked: backToSearchResults() }
                }

                // === MY LIST ===
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    visible: window.topView === "mylist"

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(64); color: "transparent"
                        RowLayout {
                            anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(10)
                            StyledInput {
                                id: listFilterInput
                                placeholderText: "Search your list\u2026"
                                onTextChanged: { window.listFilterText = text; applyListFilter() }
                            }
                            ActionButton {
                                label: "+ Add"; filled: true
                                accent: window.blue
                                Layout.preferredWidth: window.s(90)
                                onClicked: openAddPanel()
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true

                        ColumnLayout {
                            anchors.centerIn: parent; spacing: window.s(10)
                            visible: myListModel.count === 0
                            Text { Layout.alignment: Qt.AlignHCenter; text: "\uD83C\uDFAC"; font.pixelSize: window.s(32) }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "Your list is empty"
                                color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Bold
                            }
                            Text { Layout.alignment: Qt.AlignHCenter; text: "Tap + Add to build it"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: myListModel.count > 0 && filteredListModel.count === 0
                            text: "No matches in your list"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                        }

                        GridView {
                            anchors.fill: parent; anchors.margins: window.s(15)
                            visible: filteredListModel.count > 0
                            model: filteredListModel
                            cellWidth: Math.floor(width / window.posterColumns); cellHeight: cellWidth * 1.45 + window.s(44)
                            boundsBehavior: Flickable.StopAtBounds; clip: true
                            ScrollBar.vertical: ScrollBar { active: true; contentItem: Rectangle { radius: window.s(2); color: window.surface2 } }
                            delegate: ManualEntryCard {}
                        }
                    }
                }
            }
        }
    }

    // ---- EPISODE PICKER MODAL (overlay) ----
    Rectangle {
        id: episodePickerOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.7)
        opacity: window.episodePickerOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuart } }
        z: 101
        MouseArea { anchors.fill: parent; onClicked: closeEpisodePicker() }

        Rectangle {
            width: window.s(480)
            height: window.s(560)
            anchors.centerIn: parent
            radius: window.s(14)
            color: window.base
            border.color: window.surface2
            border.width: 1
            clip: true
            scale: window.episodePickerOpen ? 1.0 : 0.94
            Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(70)
                    color: window.surface0
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: window.surface1 }
                    RowLayout {
                        anchors.fill: parent; anchors.margins: window.s(14)
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: window.s(3)
                            Text {
                                text: window.pickerMode === "seasons" ? "Select Season" : "Select Episode"
                                color: window.text
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(15)
                            }
                            Text {
                                text: window.seriesTitle
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            width: window.s(28); height: window.s(28); hoverEnabled: true
                            onClicked: closeEpisodePicker()
                            Rectangle { anchors.fill: parent; radius: window.s(8); color: parent.containsMouse ? window.surface2 : "transparent" }
                            Text { anchors.centerIn: parent; text: "×"; color: window.subtext0; font.pixelSize: window.s(18) }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(52)
                    color: "transparent"
                    visible: window.pickerMode === "episodes"
                    ListView {
                        anchors.fill: parent; anchors.margins: window.s(10)
                        orientation: ListView.Horizontal
                        model: seasonModel
                        spacing: window.s(8)
                        clip: true
                        delegate: SeasonChip {}
                    }
                }

                ListView {
                    id: episodePickerList
                    Layout.fillWidth: true; Layout.fillHeight: true
                    anchors.margins: window.s(12)
                    model: window.pickerMode === "seasons" ? seasonModel : episodeModel
                    spacing: window.s(6)
                    clip: true
                    delegate: window.pickerMode === "seasons" ? seasonRowDelegate : episodeRowDelegate
                }

                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(56)
                    color: window.surface0
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: window.surface1 }
                    RowLayout {
                        anchors.fill: parent; anchors.margins: window.s(12)
                        Item { Layout.fillWidth: true }
                        ActionButton {
                            label: "Close"
                            Layout.preferredWidth: window.s(80)
                            onClicked: closeEpisodePicker()
                        }
                    }
                }
            }
        }
    }

    Component { id: episodeRowDelegate; EpisodeRow {} }
    Component { id: seasonRowDelegate; SeasonRow {} }

    // ---- VIEW INFO SITE PICKER (overlay) ----
    // A fixed list of five named, legitimate destinations. Each row calls
    // a hardcoded function above — there is no "add a source" input here,
    // on purpose, so this can't turn back into an open/swappable list.
    Rectangle {
        id: sitePickerOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.7)
        opacity: window.sitePickerOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuart } }
        z: 102
        MouseArea { anchors.fill: parent; onClicked: closeSitePicker() }

        Rectangle {
            width: window.s(280)
            height: siteListCol.implicitHeight + window.s(28)
            anchors.centerIn: parent
            radius: window.s(14)
            color: window.base
            border.color: window.surface2
            border.width: 1
            scale: window.sitePickerOpen ? 1.0 : 0.94
            Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: siteListCol
                anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(8)

                Text {
                    Layout.fillWidth: true
                    text: "View Info On"
                    color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(14)
                }
                Text {
                    Layout.fillWidth: true; Layout.bottomMargin: window.s(4)
                    text: window.pickerTitle
                    color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                    elide: Text.ElideRight
                }

                SitePickerRow {
                    Layout.fillWidth: true
                    label: "IMDb"; sub: "Ratings & reviews"; accent: window.yellow
                    onClicked: { closeSitePicker(); openImdb(window.pickerImdbId) }
                }
                SitePickerRow {
                    Layout.fillWidth: true
                    label: "MyAnimeList"; sub: "Search this title"; accent: window.blue
                    onClicked: { closeSitePicker(); openMalSearch(window.pickerTitle) }
                }
                SitePickerRow {
                    Layout.fillWidth: true
                    label: "Netflix"; sub: "Search this title"; accent: window.red
                    onClicked: { closeSitePicker(); openNetflixSearch(window.pickerTitle) }
                }
            }
        }
    }

    // ---- ADD-TO-MY-LIST PANEL (overlay) ----
    Rectangle {
        id: addPanelOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.7)
        opacity: window.addPanelOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuart } }
        z: 100
        MouseArea { anchors.fill: parent; onClicked: closeAddPanel() }

        Rectangle {
            id: addCard
            width: window.s(440)
            anchors.top: parent.top; anchors.bottom: parent.bottom
            anchors.topMargin: window.s(30); anchors.bottomMargin: window.s(30)
            anchors.horizontalCenter: parent.horizontalCenter
            radius: window.s(14); color: window.base; border.color: window.surface2; border.width: 1
            clip: true
            scale: window.addPanelOpen ? 1.0 : 0.94
            Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent; spacing: 0

                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(64); color: window.surface0
                    Rectangle { width: parent.width; height: 1; color: window.surface1; anchors.bottom: parent.bottom }
                    RowLayout {
                        anchors.fill: parent; anchors.margins: window.s(14)
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: window.s(2)
                            Text {
                                text: window.addPanelCategory === "series" ? "Add a Series" : "Add a Movie"
                                color: window.text; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(15)
                            }
                            Text { text: "Search, or enter details manually"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11) }
                        }
                        IconButton { glyph: "\u00D7"; onClicked: closeAddPanel() }
                    }
                }

                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(10)

                        Rectangle {
                            Layout.preferredWidth: window.s(200); Layout.preferredHeight: window.s(34); radius: window.s(9); color: window.surface0
                            Rectangle {
                                width: parent.width / 2 - window.s(4); height: parent.height - window.s(8)
                                y: window.s(4); radius: window.s(7)
                                color: window.addPanelCategory === "series" ? window.blue : window.mauve
                                x: window.addPanelCategory === "series" ? parent.width / 2 : window.s(4)
                                Behavior on x { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                                Behavior on color { ColorAnimation { duration: 250 } }
                            }
                            RowLayout {
                                anchors.fill: parent; spacing: 0
                                MouseArea {
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    onClicked: { window.addPanelCategory = "movie"; window.lastAddCategory = "movie"; window.manualTypeIsSeries = false; addPanelResultsModel.clear(); window.addPanelSearched = false }
                                    Text { anchors.centerIn: parent; text: "Movies"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: window.addPanelCategory === "movie" ? Font.Bold : Font.Medium; color: window.addPanelCategory === "movie" ? window.crust : window.text }
                                }
                                MouseArea {
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    onClicked: { window.addPanelCategory = "series"; window.lastAddCategory = "series"; window.manualTypeIsSeries = true; addPanelResultsModel.clear(); window.addPanelSearched = false }
                                    Text { anchors.centerIn: parent; text: "Series"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: window.addPanelCategory === "series" ? Font.Bold : Font.Medium; color: window.addPanelCategory === "series" ? window.crust : window.text }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true; spacing: window.s(8)
                            StyledInput {
                                id: addTitleInput
                                placeholderText: window.addPanelCategory === "series" ? "Series title\u2026" : "Movie title\u2026"
                                Keys.onReturnPressed: { runAddSearch(); event.accepted = true }
                            }
                            ActionButton { label: "Search"; filled: true; accent: window.blue; Layout.preferredWidth: window.s(80); onClicked: runAddSearch() }
                        }

                        Item {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            Text {
                                anchors.centerIn: parent; visible: window.addPanelSearching
                                text: "Searching\u2026"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !window.addPanelSearching && window.addPanelSearched && addPanelResultsModel.count === 0
                                text: "No matches \u2014 try entering details manually below"
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                width: parent.width - window.s(20); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                            }
                            ListView {
                                anchors.fill: parent
                                visible: addPanelResultsModel.count > 0 && !window.addPanelSearching
                                model: addPanelResultsModel; spacing: window.s(6); clip: true
                                ScrollBar.vertical: ScrollBar { active: true; contentItem: Rectangle { radius: window.s(2); color: window.surface2 } }
                                delegate: CandidateRow {}
                            }
                        }

                        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: window.surface1 }

                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: window.s(34); radius: window.s(9)
                            color: manualToggleMouse.containsMouse ? window.surface1 : "transparent"
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                anchors.centerIn: parent
                                text: window.manualFieldsOpen ? "\u2212 Hide manual entry" : "+ Enter details manually"
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                            }
                            MouseArea { id: manualToggleMouse; anchors.fill: parent; hoverEnabled: true; onClicked: window.manualFieldsOpen = !window.manualFieldsOpen }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true; spacing: window.s(8)
                            visible: window.manualFieldsOpen

                            StyledInput { id: manualTitleInput; placeholderText: "Title *" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: window.s(8)
                                StyledInput { id: manualYearInput; placeholderText: "Year" }
                                StyledInput { id: manualIdInput; placeholderText: "IMDb ID, e.g. tt0111161" }
                            }
                            StyledInput { id: manualPosterInput; placeholderText: "Poster image URL (optional)" }
                            StyledInput { id: manualNotesInput; placeholderText: "Notes / synopsis (optional)" }

                            RowLayout {
                                Layout.fillWidth: true; spacing: window.s(8)
                                Text { text: "Type:"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                                ActionButton { label: "Movie"; filled: !window.manualTypeIsSeries; accent: window.mauve; Layout.preferredWidth: window.s(90); implicitHeight: window.s(30); onClicked: window.manualTypeIsSeries = false }
                                ActionButton { label: "Series"; filled: window.manualTypeIsSeries; accent: window.blue; Layout.preferredWidth: window.s(90); implicitHeight: window.s(30); onClicked: window.manualTypeIsSeries = true }
                            }

                            RowLayout {
                                Layout.fillWidth: true; spacing: window.s(8)
                                ActionButton { Layout.fillWidth: true; label: "Cancel"; onClicked: closeAddPanel() }
                                ActionButton { Layout.fillWidth: true; label: "Save"; filled: true; accent: window.green; onClicked: saveManualFieldsEntry() }
                            }
                        }
                    }
                }
            }
        }
    }
}
//        Quickshell.execDetached(["xdg-open", "https://player.imdb.su/embed/movie/" + imdbId + "/"])
