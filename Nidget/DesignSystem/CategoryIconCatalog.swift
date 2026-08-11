import Foundation

// MARK: - CategoryIconCatalog
//
// The hand-picked SF Symbols a category can wear. Deliberately NOT the full ~6900-symbol set:
// a person naming an envelope wants "the food one", not a symbol browser, so this is a curated
// couple of hundred that actually map onto how money gets spent, grouped the way a budget is.
// Every name in here is a long-established symbol — a typo would compile fine and render a blank
// box on device, so the list stays conservative on purpose and skips anything uncertain.
//
// `search(_:)` matches the symbol name AND a small map of human words, because nobody guesses
// "takeoutbag.and.cup.and.straw.fill" from the word "takeout". `suggested(forCategoryName:)`
// reads a category's name and offers an icon, so a brand-new "Groceries" arrives already wearing
// a shopping cart instead of a blank circle.
//
// Icons are local-only (Actual's server has no icon column on categories) and live in
// `Preferences.categoryIcons`; nothing here ever touches the sync layer.

// MARK: - Section

struct CategoryIconSection: Identifiable {
    let title: String
    let symbols: [String]

    var id: String { title }
}

// MARK: - Catalog

enum CategoryIconCatalog {
    /// Drawn (dimmed) wherever a category has no icon of its own yet.
    static let fallback = "circle.grid.2x2"

    static let sections: [CategoryIconSection] = [
        CategoryIconSection(title: "Money", symbols: [
            "dollarsign.circle.fill", "banknote.fill", "creditcard.fill", "wallet.pass.fill",
            "building.columns.fill", "chart.line.uptrend.xyaxis", "chart.xyaxis.line",
            "chart.pie.fill", "chart.bar.fill", "percent", "arrow.left.arrow.right",
            "arrow.up.arrow.down", "arrow.triangle.2.circlepath", "repeat",
            "calendar.badge.clock", "checkmark.seal.fill", "lock.shield.fill", "shield.fill",
            "signature", "scroll.fill", "hourglass", "eurosign.circle.fill",
            "sterlingsign.circle.fill", "indianrupeesign.circle.fill", "bitcoinsign.circle.fill",
        ]),
        CategoryIconSection(title: "Food & Drink", symbols: [
            "fork.knife", "fork.knife.circle.fill", "cup.and.saucer.fill", "wineglass.fill",
            "takeoutbag.and.cup.and.straw.fill", "carrot.fill", "fish.fill",
            "birthday.cake.fill", "popcorn.fill", "cart.fill", "basket.fill", "leaf.fill",
        ]),
        CategoryIconSection(title: "Home", symbols: [
            "house.fill", "house", "building.fill", "bed.double.fill", "sofa.fill",
            "lightbulb.fill", "key.fill", "lock.fill", "hammer.fill",
            "wrench.and.screwdriver.fill", "screwdriver.fill", "paintbrush.fill",
            "paintbrush.pointed.fill", "ruler.fill", "shippingbox.fill", "cube.fill", "scissors",
        ]),
        CategoryIconSection(title: "Transport", symbols: [
            "car.fill", "car.2.fill", "bus.fill", "tram.fill", "bicycle", "fuelpump.fill",
            "parkingsign", "figure.walk", "location.fill",
        ]),
        CategoryIconSection(title: "Bills & Utilities", symbols: [
            "bolt.fill", "drop.fill", "flame.fill", "wifi", "phone.fill",
            "antenna.radiowaves.left.and.right", "network", "tv.fill", "play.rectangle.fill",
            "umbrella.fill", "trash.fill", "arrow.3.trianglepath", "snowflake", "sun.max.fill",
        ]),
        CategoryIconSection(title: "Shopping", symbols: [
            "bag.fill", "tag.fill", "tshirt.fill", "comb.fill", "sparkles", "gift.fill",
            "crown.fill", "iphone", "ipad", "applewatch", "headphones", "keyboard",
        ]),
        CategoryIconSection(title: "Health", symbols: [
            "cross.case.fill", "pills.fill", "stethoscope", "bandage.fill", "cross.fill",
            "heart.fill", "heart.circle.fill", "heart.text.square.fill", "waveform.path.ecg",
            "lungs.fill", "brain.head.profile", "tooth.fill", "eyeglasses", "eye.fill",
            "figure.run", "dumbbell.fill", "scalemass.fill",
        ]),
        CategoryIconSection(title: "Fun", symbols: [
            "gamecontroller.fill", "puzzlepiece.fill", "die.face.5.fill", "theatermasks.fill",
            "paintpalette.fill", "guitars.fill", "music.note", "music.note.list",
            "speaker.wave.2.fill", "mic.fill", "film.fill", "ticket.fill", "camera.fill",
            "photo.fill", "sportscourt.fill", "trophy.fill", "star.fill", "binoculars.fill",
        ]),
        CategoryIconSection(title: "Travel", symbols: [
            "airplane", "airplane.departure", "suitcase.fill", "globe", "globe.americas.fill",
            "map.fill", "mappin.and.ellipse", "tent.fill", "building.2.fill", "moon.fill",
        ]),
        CategoryIconSection(title: "Work & School", symbols: [
            "briefcase.fill", "graduationcap.fill", "book.fill", "books.vertical.fill", "pencil",
            "paperclip", "desktopcomputer", "laptopcomputer", "printer.fill", "doc.fill",
            "doc.text.fill", "folder.fill", "tray.full.fill", "envelope.fill", "newspaper.fill",
            "calendar", "clock.fill", "alarm.fill", "timer", "person.2.fill", "person.3.fill",
            "person.crop.circle.fill", "gearshape.fill",
        ]),
        CategoryIconSection(title: "Family & Pets", symbols: [
            "person.fill", "figure.and.child.holdinghands", "pawprint.fill", "hare.fill",
            "tortoise.fill", "ant.fill", "ladybug.fill", "hands.sparkles.fill",
            "hand.thumbsup.fill",
        ]),
        CategoryIconSection(title: "Other", symbols: [
            "circle.grid.2x2", "square.grid.2x2.fill", "circle.dashed", "seal.fill",
            "ellipsis.circle.fill", "questionmark.circle.fill", "bell.fill", "bookmark.fill",
            "flag.fill", "target", "exclamationmark.triangle.fill", "cloud.fill",
            "plus.circle.fill", "minus.circle.fill",
        ]),
    ]

    /// Every catalog symbol, in section order — the list `search(_:)` walks.
    static let allSymbols: [String] = sections.flatMap(\.symbols)

    // MARK: Search

    /// Symbols whose name matches `query`, or whose everyday words do. Empty query = no results
    /// (the picker shows its grouped sections instead).
    static func search(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return allSymbols.filter { symbol in
            if symbol.contains(needle) { return true }
            guard let words = keywords[symbol] else { return false }
            return words.contains { $0.contains(needle) }
        }
    }

    /// "cup.and.saucer.fill" → "cup and saucer". Used for VoiceOver labels.
    static func label(for symbol: String) -> String {
        symbol
            .replacingOccurrences(of: ".fill", with: "")
            .replacingOccurrences(of: ".", with: " ")
    }

    /// Everyday words for symbols whose own name doesn't already contain the obvious one, so
    /// "rent" finds a house and "food" finds a fork.
    private static let keywords: [String: [String]] = [
        // Money
        "dollarsign.circle.fill": ["money", "cash", "income", "salary", "pay"],
        "banknote.fill": ["savings", "cash", "emergency", "money"],
        "creditcard.fill": ["debt", "loan", "fees", "payment"],
        "wallet.pass.fill": ["cash", "spending", "pocket"],
        "building.columns.fill": ["bank", "tax", "taxes", "government"],
        "chart.line.uptrend.xyaxis": ["invest", "retirement", "stocks", "growth"],
        "chart.xyaxis.line": ["invest", "growth", "reports"],
        "chart.pie.fill": ["budget", "reports", "split"],
        "chart.bar.fill": ["reports", "stats", "budget"],
        "percent": ["interest", "rate", "tax"],
        "arrow.left.arrow.right": ["transfer", "swap", "exchange"],
        "arrow.up.arrow.down": ["transfer", "in and out"],
        "arrow.triangle.2.circlepath": ["recurring", "rollover", "carryover"],
        "repeat": ["subscription", "recurring", "monthly"],
        "calendar.badge.clock": ["subscription", "recurring", "due", "bills"],
        "checkmark.seal.fill": ["paid", "done", "verified"],
        "lock.shield.fill": ["insurance", "security", "protection"],
        "shield.fill": ["insurance", "protection", "cover"],
        "signature": ["contract", "legal", "fees"],
        "scroll.fill": ["legal", "tax", "will", "document"],
        "hourglass": ["waiting", "pending", "time"],
        "eurosign.circle.fill": ["euro", "currency", "money"],
        "sterlingsign.circle.fill": ["pound", "gbp", "currency", "money"],
        "indianrupeesign.circle.fill": ["rupee", "inr", "currency", "money"],
        "bitcoinsign.circle.fill": ["crypto", "currency", "invest"],
        // Food & Drink
        "fork.knife": ["food", "restaurant", "dining", "eating out", "lunch", "dinner"],
        "fork.knife.circle.fill": ["food", "restaurant", "dining", "eating out"],
        "cup.and.saucer.fill": ["coffee", "tea", "cafe", "drinks"],
        "wineglass.fill": ["wine", "beer", "alcohol", "drinks", "pub"],
        "takeoutbag.and.cup.and.straw.fill": ["takeout", "fast food", "delivery"],
        "carrot.fill": ["vegetables", "produce", "groceries", "veg"],
        "fish.fill": ["seafood", "fishing"],
        "birthday.cake.fill": ["birthday", "party", "celebration"],
        "popcorn.fill": ["snacks", "movies", "cinema"],
        "cart.fill": ["groceries", "supermarket", "shopping"],
        "basket.fill": ["groceries", "supermarket", "market"],
        "leaf.fill": ["garden", "plants", "lawn", "green"],
        // Home
        "house.fill": ["rent", "mortgage", "home"],
        "house": ["rent", "mortgage", "home"],
        "building.fill": ["rent", "office", "property", "apartment"],
        "bed.double.fill": ["bedroom", "furniture", "hotel", "sleep"],
        "sofa.fill": ["furniture", "living room", "couch"],
        "lightbulb.fill": ["electric", "power", "utilities"],
        "key.fill": ["rent", "deposit", "keys", "home"],
        "lock.fill": ["security", "safe", "savings"],
        "hammer.fill": ["repairs", "diy", "maintenance", "tools"],
        "wrench.and.screwdriver.fill": ["repairs", "maintenance", "tools", "service"],
        "screwdriver.fill": ["repairs", "diy", "tools"],
        "paintbrush.fill": ["decorating", "diy", "painting", "art"],
        "paintbrush.pointed.fill": ["art", "decorating", "painting"],
        "ruler.fill": ["diy", "measure", "projects"],
        "shippingbox.fill": ["delivery", "packages", "moving", "storage"],
        "cube.fill": ["storage", "stuff", "misc"],
        "scissors": ["haircut", "barber", "salon", "hair"],
        // Transport
        "car.fill": ["auto", "vehicle", "driving", "commute", "taxi"],
        "car.2.fill": ["auto", "vehicles", "carpool", "commute"],
        "bus.fill": ["transit", "commute", "coach"],
        "tram.fill": ["train", "transit", "metro", "subway", "commute", "rail"],
        "bicycle": ["bike", "cycling", "commute"],
        "fuelpump.fill": ["gas", "petrol", "fuel", "diesel", "charging"],
        "parkingsign": ["parking", "car", "permit"],
        "figure.walk": ["walking", "commute", "steps"],
        "location.fill": ["local", "places", "nearby"],
        // Bills & Utilities
        "bolt.fill": ["electric", "electricity", "power", "utilities", "energy"],
        "drop.fill": ["water", "utilities", "plumbing", "sewer"],
        "flame.fill": ["gas", "heating", "utilities", "fire"],
        "wifi": ["internet", "broadband", "router"],
        "phone.fill": ["mobile", "cell", "telephone", "landline"],
        "antenna.radiowaves.left.and.right": ["cable", "signal", "broadband", "aerial"],
        "network": ["internet", "broadband", "web", "hosting"],
        "tv.fill": ["television", "cable", "streaming", "licence"],
        "play.rectangle.fill": ["streaming", "subscription", "netflix", "video"],
        "umbrella.fill": ["insurance", "rainy day", "cover"],
        "trash.fill": ["waste", "garbage", "rubbish", "bins"],
        "arrow.3.trianglepath": ["recycling", "waste", "bins"],
        "snowflake": ["heating", "cooling", "winter", "ac"],
        "sun.max.fill": ["solar", "summer", "energy"],
        // Shopping
        "bag.fill": ["shopping", "clothes", "clothing", "amazon", "shoes"],
        "tag.fill": ["deals", "sale", "labels"],
        "tshirt.fill": ["clothes", "clothing", "apparel", "laundry"],
        "comb.fill": ["hair", "grooming", "barber", "salon"],
        "sparkles": ["beauty", "cleaning", "treats", "self care"],
        "gift.fill": ["gifts", "presents", "christmas", "birthday"],
        "crown.fill": ["premium", "luxury", "treats"],
        "iphone": ["mobile", "phone", "cell", "tech"],
        "ipad": ["tablet", "tech"],
        "applewatch": ["watch", "wearable", "tech"],
        "headphones": ["music", "audio", "tech"],
        "keyboard": ["computer", "office", "tech"],
        // Health
        "cross.case.fill": ["health", "doctor", "medical", "clinic", "first aid"],
        "pills.fill": ["pharmacy", "medicine", "prescription", "meds"],
        "stethoscope": ["doctor", "medical", "health", "clinic"],
        "bandage.fill": ["first aid", "medical", "health"],
        "cross.fill": ["health", "medical", "pharmacy"],
        "heart.fill": ["health", "love", "charity", "donation"],
        "heart.circle.fill": ["health", "care", "love"],
        "heart.text.square.fill": ["health", "records", "medical"],
        "waveform.path.ecg": ["health", "medical", "checkup"],
        "lungs.fill": ["health", "medical"],
        "brain.head.profile": ["therapy", "mental health", "counselling"],
        "tooth.fill": ["dentist", "dental"],
        "eyeglasses": ["optician", "glasses", "vision"],
        "eye.fill": ["optician", "vision", "eye care"],
        "figure.run": ["gym", "fitness", "running", "exercise"],
        "dumbbell.fill": ["gym", "fitness", "weights", "workout"],
        "scalemass.fill": ["weight", "gym", "fitness"],
        // Fun
        "gamecontroller.fill": ["games", "gaming", "video games"],
        "puzzlepiece.fill": ["hobby", "games", "toys"],
        "die.face.5.fill": ["games", "board games", "dice", "hobby"],
        "theatermasks.fill": ["theatre", "theater", "shows", "entertainment"],
        "paintpalette.fill": ["art", "hobby", "crafts"],
        "guitars.fill": ["music", "lessons", "hobby"],
        "music.note": ["spotify", "streaming", "songs"],
        "music.note.list": ["playlist", "streaming", "songs"],
        "speaker.wave.2.fill": ["audio", "sound", "music"],
        "mic.fill": ["podcast", "audio", "music"],
        "film.fill": ["movies", "cinema", "entertainment"],
        "ticket.fill": ["events", "concert", "shows", "gigs"],
        "camera.fill": ["photos", "photography", "hobby"],
        "photo.fill": ["photos", "prints", "memories"],
        "sportscourt.fill": ["sports", "club", "league"],
        "trophy.fill": ["sports", "awards", "goals"],
        "star.fill": ["favourites", "favorites", "treats", "special"],
        "binoculars.fill": ["sightseeing", "outdoors", "birding"],
        // Travel
        "airplane": ["travel", "flight", "vacation", "holiday"],
        "airplane.departure": ["flights", "travel", "vacation", "holiday", "trip"],
        "suitcase.fill": ["travel", "trip", "luggage", "vacation", "holiday"],
        "globe": ["travel", "world", "abroad"],
        "globe.americas.fill": ["travel", "world", "abroad"],
        "map.fill": ["travel", "trips", "directions"],
        "mappin.and.ellipse": ["places", "location", "travel"],
        "tent.fill": ["camping", "outdoors", "travel"],
        "building.2.fill": ["hotel", "city", "office", "property"],
        "moon.fill": ["night", "sleep", "nights away"],
        // Work & School
        "briefcase.fill": ["work", "business", "job", "office"],
        "graduationcap.fill": ["school", "tuition", "college", "education", "kids"],
        "book.fill": ["books", "reading", "study", "education"],
        "books.vertical.fill": ["books", "library", "education"],
        "pencil": ["stationery", "supplies", "school", "writing"],
        "paperclip": ["office", "supplies", "admin"],
        "desktopcomputer": ["computer", "office", "tech", "pc"],
        "laptopcomputer": ["computer", "tech", "software"],
        "printer.fill": ["office", "printing", "supplies"],
        "doc.fill": ["documents", "paperwork", "admin"],
        "doc.text.fill": ["documents", "paperwork", "admin", "bills"],
        "folder.fill": ["files", "admin", "paperwork"],
        "tray.full.fill": ["inbox", "admin", "mail"],
        "envelope.fill": ["mail", "post", "postage", "letters"],
        "newspaper.fill": ["news", "magazine", "subscription", "press"],
        "calendar": ["monthly", "annual", "schedule", "dates"],
        "clock.fill": ["time", "hourly", "schedule"],
        "alarm.fill": ["reminder", "due", "time"],
        "timer": ["time", "hourly"],
        "person.2.fill": ["family", "friends", "people", "shared"],
        "person.3.fill": ["family", "group", "people", "team"],
        "person.crop.circle.fill": ["personal", "profile", "me"],
        "gearshape.fill": ["settings", "service", "misc"],
        // Family & Pets
        "person.fill": ["personal", "me", "allowance", "spending money"],
        "figure.and.child.holdinghands": ["kids", "children", "childcare", "daycare", "family"],
        "pawprint.fill": ["pet", "pets", "dog", "cat", "vet"],
        "hare.fill": ["pets", "animals", "rabbit"],
        "tortoise.fill": ["pets", "animals"],
        "ant.fill": ["pests", "pest control", "bugs"],
        "ladybug.fill": ["pests", "bugs", "garden"],
        "hands.sparkles.fill": ["charity", "giving", "donation", "tithe"],
        "hand.thumbsup.fill": ["treats", "good", "fun"],
        // Other
        "circle.grid.2x2": ["other", "misc", "general"],
        "square.grid.2x2.fill": ["other", "misc", "apps"],
        "circle.dashed": ["other", "misc", "empty", "none"],
        "seal.fill": ["badge", "misc", "quality"],
        "ellipsis.circle.fill": ["other", "misc"],
        "questionmark.circle.fill": ["unknown", "other", "misc"],
        "bell.fill": ["reminders", "alerts", "due"],
        "bookmark.fill": ["saved", "favourites", "favorites"],
        "flag.fill": ["goals", "milestones", "targets"],
        "target": ["goals", "savings goal", "targets"],
        "exclamationmark.triangle.fill": ["warning", "overspend", "urgent"],
        "cloud.fill": ["cloud", "storage", "subscription", "weather"],
        "plus.circle.fill": ["add", "extra", "more"],
        "minus.circle.fill": ["less", "reduce"],
    ]

    // MARK: Suggestion

    /// A first guess at an icon from a category's name, so a fresh envelope isn't born blank.
    /// Returns nil when nothing matches — a wrong icon is worse than none.
    static func suggested(forCategoryName name: String) -> String? {
        let cleaned = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
        guard !cleaned.isEmpty else { return nil }
        // Padded with spaces so short rules can be written word-bounded (" bus " must not match
        // "business", " rent " must not match "parents").
        let haystack = " \(cleaned) "
        for rule in suggestionRules where haystack.contains(rule.word) {
            return rule.symbol
        }
        return nil
    }

    /// Ordered most specific first: the first hit wins, so "Childcare" resolves as a child rule
    /// before the " car " rule ever sees it.
    private static let suggestionRules: [(word: String, symbol: String)] = [
        // Food (pet food is pet food, so it goes ahead of the food rules)
        ("dog food", "pawprint.fill"),
        ("cat food", "pawprint.fill"),
        ("pet food", "pawprint.fill"),
        ("grocer", "cart.fill"),
        ("supermarket", "cart.fill"),
        ("restaurant", "fork.knife"),
        ("eating out", "fork.knife"),
        ("dining", "fork.knife"),
        ("takeout", "takeoutbag.and.cup.and.straw.fill"),
        ("take out", "takeoutbag.and.cup.and.straw.fill"),
        ("takeaway", "takeoutbag.and.cup.and.straw.fill"),
        ("coffee", "cup.and.saucer.fill"),
        ("cafe", "cup.and.saucer.fill"),
        ("wine", "wineglass.fill"),
        ("beer", "wineglass.fill"),
        ("alcohol", "wineglass.fill"),
        (" pub ", "wineglass.fill"),
        (" food ", "fork.knife"),
        ("lunch", "fork.knife"),
        ("dinner", "fork.knife"),
        ("snack", "popcorn.fill"),
        // Family & school (before the vehicle rules: "childcare" contains "car")
        ("daycare", "figure.and.child.holdinghands"),
        ("childcare", "figure.and.child.holdinghands"),
        ("child", "figure.and.child.holdinghands"),
        (" kid", "figure.and.child.holdinghands"),
        ("baby", "figure.and.child.holdinghands"),
        ("school", "graduationcap.fill"),
        ("tuition", "graduationcap.fill"),
        ("college", "graduationcap.fill"),
        ("student", "graduationcap.fill"),
        ("educat", "graduationcap.fill"),
        ("book", "book.fill"),
        // Home
        (" rent ", "house.fill"),
        ("mortgage", "house.fill"),
        (" home ", "house.fill"),
        ("house", "house.fill"),
        ("furniture", "sofa.fill"),
        ("repair", "wrench.and.screwdriver.fill"),
        ("maintenance", "wrench.and.screwdriver.fill"),
        ("garden", "leaf.fill"),
        ("lawn", "leaf.fill"),
        ("cleaning", "sparkles"),
        ("laundry", "tshirt.fill"),
        // Transport
        ("parking", "parkingsign"),
        ("transit", "tram.fill"),
        ("train", "tram.fill"),
        ("subway", "tram.fill"),
        ("metro", "tram.fill"),
        (" bus ", "bus.fill"),
        ("commut", "tram.fill"),
        (" bike", "bicycle"),
        (" cycl", "bicycle"),   // bounded so "recycling" stays recycling
        (" gas ", "fuelpump.fill"),
        ("fuel", "fuelpump.fill"),
        ("petrol", "fuelpump.fill"),
        (" car ", "car.fill"),
        ("auto", "car.fill"),
        ("vehicle", "car.fill"),
        ("taxi", "car.fill"),
        ("uber", "car.fill"),
        // Bills & utilities
        ("internet", "wifi"),
        ("broadband", "wifi"),
        ("wifi", "wifi"),
        ("phone", "phone.fill"),
        ("mobile", "phone.fill"),
        ("insurance", "shield.fill"),
        ("util", "bolt.fill"),
        ("electric", "bolt.fill"),
        (" power ", "bolt.fill"),
        ("energy", "bolt.fill"),
        ("solar", "sun.max.fill"),
        ("water", "drop.fill"),
        ("sewer", "drop.fill"),
        (" heat", "flame.fill"),   // bounded: "theater" contains "heat"
        ("recycl", "arrow.3.trianglepath"),
        ("trash", "trash.fill"),
        ("waste", "trash.fill"),
        ("garbage", "trash.fill"),
        ("rubbish", "trash.fill"),
        // Health
        ("health", "cross.case.fill"),
        ("doctor", "cross.case.fill"),
        ("medical", "cross.case.fill"),
        ("pharmacy", "pills.fill"),
        ("dentist", "tooth.fill"),
        ("dental", "tooth.fill"),
        ("therapy", "brain.head.profile"),
        ("optic", "eyeglasses"),
        (" vision", "eyeglasses"),   // bounded: "television" contains "vision"
        ("glasses", "eyeglasses"),
        (" gym ", "figure.run"),
        ("fitness", "figure.run"),
        ("workout", "dumbbell.fill"),
        ("sport", "sportscourt.fill"),
        // Pets
        (" pet", "pawprint.fill"),
        (" dog", "pawprint.fill"),
        ("puppy", "pawprint.fill"),
        ("kitten", "pawprint.fill"),
        (" vet ", "pawprint.fill"),
        // Travel & fun
        ("travel", "airplane"),
        ("vacation", "airplane"),
        ("holiday", "airplane"),
        ("flight", "airplane"),
        (" trip", "suitcase.fill"),
        ("hotel", "bed.double.fill"),
        ("camping", "tent.fill"),
        ("movie", "film.fill"),
        ("cinema", "film.fill"),
        ("game", "gamecontroller.fill"),
        ("concert", "ticket.fill"),
        ("ticket", "ticket.fill"),
        ("entertain", "theatermasks.fill"),
        ("hobb", "paintpalette.fill"),
        ("music", "music.note"),
        (" fun ", "star.fill"),
        // Gifts & giving
        ("gift", "gift.fill"),
        ("present", "gift.fill"),
        ("christmas", "gift.fill"),
        ("birthday", "birthday.cake.fill"),
        ("charity", "hands.sparkles.fill"),
        ("donat", "hands.sparkles.fill"),
        ("tithe", "hands.sparkles.fill"),
        // Shopping & personal
        ("apparel", "bag.fill"),
        ("cloth", "bag.fill"),
        ("shopping", "bag.fill"),
        ("amazon", "bag.fill"),
        ("shoes", "bag.fill"),
        ("hair", "scissors"),
        ("barber", "scissors"),
        ("salon", "scissors"),
        ("beauty", "sparkles"),
        ("personal", "person.fill"),
        ("allowance", "person.fill"),
        ("pocket money", "person.fill"),
        // Saving & investing
        ("saving", "banknote.fill"),
        (" save", "banknote.fill"),
        ("emergency", "banknote.fill"),
        ("invest", "chart.line.uptrend.xyaxis"),
        ("retire", "chart.line.uptrend.xyaxis"),
        ("pension", "chart.line.uptrend.xyaxis"),
        ("stock", "chart.line.uptrend.xyaxis"),
        // Money in and out
        ("salary", "dollarsign.circle.fill"),
        ("paycheck", "dollarsign.circle.fill"),
        ("income", "dollarsign.circle.fill"),
        ("wage", "dollarsign.circle.fill"),
        ("bonus", "dollarsign.circle.fill"),
        (" tax", "building.columns.fill"),
        (" bank", "building.columns.fill"),
        (" loan", "creditcard.fill"),
        (" debt", "creditcard.fill"),
        ("credit", "creditcard.fill"),
        (" fee", "creditcard.fill"),
        ("streaming", "play.rectangle.fill"),
        ("netflix", "play.rectangle.fill"),
        ("sub", "play.rectangle.fill"),
        // Work & admin
        ("computer", "laptopcomputer"),
        ("software", "laptopcomputer"),
        (" tech", "laptopcomputer"),
        (" work", "briefcase.fill"),
        ("office", "briefcase.fill"),
        ("business", "briefcase.fill"),
        (" mail", "envelope.fill"),
        ("postage", "envelope.fill"),
        ("news", "newspaper.fill"),
        ("misc", "circle.grid.2x2"),
    ]
}
