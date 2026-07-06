import SwiftUI
import Supabase

// MARK: - Date helpers

enum CalFmt {
    static var central: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Config.timeZone
        return c
    }
    static func dayKey(_ date: Date, tz: TimeZone = Config.timeZone) -> String {
        let f = DateFormatter(); f.calendar = central; f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func dayKeyUTC(_ date: Date) -> String { dayKey(date, tz: TimeZone(identifier: "UTC")!) }

    static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "MMM d"
        return f.string(from: date)
    }
    static func dayHeader(_ date: Date) -> String {
        let cal = central
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        let f = DateFormatter(); f.timeZone = Config.timeZone
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "EEE, MMM d, yyyy"
        return f.string(from: date).uppercased()
    }
    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "LLLL yyyy"
        return f.string(from: date)
    }
}

struct Occurrence: Identifiable, Hashable {
    let event: CalEvent
    let start: Date
    let end: Date
    let occKey: String
    var id: String { "\(event.id.uuidString)-\(occKey)" }
    var isMultiDay: Bool { !CalFmt.central.isDate(start, inSameDayAs: end) }
}

// A single day an occurrence appears on (a multi-day event yields one per day).
struct DaySlice: Identifiable, Hashable {
    let occ: Occurrence
    let day: Date
    let isStart: Bool
    let isEnd: Bool
    var id: String { "\(occ.event.id.uuidString)-\(occ.occKey)-\(CalFmt.dayKey(day))" }
}

// MARK: - Model

@MainActor
@Observable
final class CalendarModel {
    var events: [CalEvent] = []
    var rsvps: [EventRSVP] = []
    var loading = true
    var currentMemberId: UUID?
    var errorText: String?

    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var db: SupabaseClient { SupabaseManager.client }

    func start() async {
        await load()
        await subscribe()
    }
    func stop() {
        listenTask?.cancel(); listenTask = nil
        if let channel { Task { await db.removeChannel(channel) } }
        channel = nil
    }

    func load() async {
        events = (try? await TriviaService.events()) ?? []
        rsvps = (try? await TriviaService.eventRSVPs()) ?? []
        loading = false
    }

    private func subscribe() async {
        let channel = db.channel("public:calendar")
        self.channel = channel
        let evIns = channel.postgresChange(InsertAction.self, schema: "public", table: "events")
        let evUpd = channel.postgresChange(UpdateAction.self, schema: "public", table: "events")
        let evDel = channel.postgresChange(DeleteAction.self, schema: "public", table: "events")
        let rvIns = channel.postgresChange(InsertAction.self, schema: "public", table: "event_rsvps")
        let rvUpd = channel.postgresChange(UpdateAction.self, schema: "public", table: "event_rsvps")
        let rvDel = channel.postgresChange(DeleteAction.self, schema: "public", table: "event_rsvps")
        await channel.subscribe()
        listenTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in evIns { await self?.load() } }
                group.addTask { for await _ in evUpd { await self?.load() } }
                group.addTask { for await _ in evDel { await self?.load() } }
                group.addTask { for await _ in rvIns { await self?.load() } }
                group.addTask { for await _ in rvUpd { await self?.load() } }
                group.addTask { for await _ in rvDel { await self?.load() } }
            }
        }
    }

    // Expand events into occurrences within [from, to].
    func occurrences(from: Date, to: Date) -> [Occurrence] {
        var out: [Occurrence] = []
        let cal = CalFmt.central
        for e in events {
            let duration = max(0, e.endsAt.timeIntervalSince(e.startsAt))
            if e.recurrence == .none {
                if e.startsAt <= to && e.startsAt.addingTimeInterval(duration) >= from {
                    out.append(Occurrence(event: e, start: e.startsAt, end: e.endsAt, occKey: CalFmt.dayKey(e.startsAt)))
                }
                continue
            }
            let untilKey = e.recurrenceUntil.map { CalFmt.dayKeyUTC($0) }
            var s = e.startsAt
            var guardN = 0
            while s <= to && guardN < 500 {
                if let uk = untilKey, CalFmt.dayKey(s) > uk { break }
                if s.addingTimeInterval(duration) >= from {
                    out.append(Occurrence(event: e, start: s, end: s.addingTimeInterval(duration), occKey: CalFmt.dayKey(s)))
                }
                s = next(s, e.recurrence, cal)
                guardN += 1
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private func next(_ d: Date, _ r: Recurrence, _ cal: Calendar) -> Date {
        switch r {
        case .daily:    return cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
        case .weekly:   return cal.date(byAdding: .day, value: 7, to: d) ?? d.addingTimeInterval(604800)
        case .biweekly: return cal.date(byAdding: .day, value: 14, to: d) ?? d.addingTimeInterval(1209600)
        case .monthly:  return cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(2629800)
        case .none:     return d.addingTimeInterval(1e12)
        }
    }

    func rsvps(for occ: Occurrence) -> [EventRSVP] {
        rsvps.filter { $0.eventId == occ.event.id && $0.occurrence == occ.occKey }
    }
    func myStatus(_ occ: Occurrence) -> RSVPStatus? {
        rsvps.first { $0.eventId == occ.event.id && $0.occurrence == occ.occKey && $0.memberId == currentMemberId }?.status
    }
    func counts(_ occ: Occurrence) -> (yes: Int, no: Int, maybe: Int) {
        let r = rsvps(for: occ)
        return (r.filter { $0.status == .yes }.count, r.filter { $0.status == .no }.count, r.filter { $0.status == .maybe }.count)
    }

    func setRSVP(_ occ: Occurrence, _ status: RSVPStatus) async {
        guard let me = currentMemberId else { return }
        do {
            if myStatus(occ) == status {
                try await TriviaService.removeRSVP(eventId: occ.event.id, memberId: me, occurrence: occ.occKey)
            } else {
                try await TriviaService.setRSVP(eventId: occ.event.id, memberId: me, occurrence: occ.occKey, status: status)
            }
            await load()
        } catch { errorText = "Couldn't save your RSVP." }
    }

    func delete(_ event: CalEvent) async {
        do { try await TriviaService.deleteEvent(id: event.id); await load() }
        catch { errorText = "Couldn't delete that event." }
    }
}

// MARK: - Calendar screen

struct CalendarView: View {
    @Environment(AppState.self) private var app
    @State private var model = CalendarModel()
    @State private var monthAnchor = CalFmt.central.date(from: CalFmt.central.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selectedDay = Calendar(identifier: .gregorian).startOfDay(for: Date())
    @State private var showCreate = false
    @State private var editing: CalEvent?
    @State private var detail: Occurrence?

    private var windowStart: Date { CalFmt.central.startOfDay(for: Date()) }
    private var windowEnd: Date { CalFmt.central.date(byAdding: .day, value: 120, to: windowStart) ?? windowStart }

    // Each occurrence appears on every day it spans (start → end), grouped by day.
    private var agenda: [(day: Date, items: [DaySlice])] {
        let cal = CalFmt.central
        var slices: [DaySlice] = []
        for o in model.occurrences(from: windowStart, to: windowEnd) {
            let startDay = cal.startOfDay(for: o.start)
            let endDay = cal.startOfDay(for: o.end)
            var day = startDay, n = 0
            while day <= endDay && n < 90 {
                if day >= windowStart && day <= windowEnd {
                    slices.append(DaySlice(occ: o, day: day,
                                           isStart: cal.isDate(day, inSameDayAs: startDay),
                                           isEnd: cal.isDate(day, inSameDayAs: endDay)))
                }
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                n += 1
            }
        }
        let grouped = Dictionary(grouping: slices) { CalFmt.dayKey($0.day) }
        return grouped.keys.sorted().compactMap { key in
            guard let items = grouped[key], let first = items.first else { return nil }
            return (first.day, items.sorted { $0.occ.start < $1.occ.start })
        }
    }

    // Single-day events show a dot on their day; multi-day events show a line
    // spanning every day they cover.
    private var monthMarks: (dots: Set<String>, spans: Set<String>) {
        let cal = CalFmt.central
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        guard let start = cal.date(from: comps),
              let end = cal.date(byAdding: DateComponents(month: 1, day: 1), to: start) else { return ([], []) }
        var dots = Set<String>()
        var spans = Set<String>()
        for o in model.occurrences(from: start, to: end) {
            if o.isMultiDay {
                var day = cal.startOfDay(for: o.start)
                let endDay = cal.startOfDay(for: o.end)
                var n = 0
                while day <= endDay && n < 90 {
                    spans.insert(CalFmt.dayKey(day))
                    day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                    n += 1
                }
            } else {
                dots.insert(CalFmt.dayKey(o.start))
            }
        }
        return (dots, spans)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            MonthGrid(monthAnchor: $monthAnchor, selectedDay: $selectedDay,
                                      dotDays: monthMarks.dots, spanDays: monthMarks.spans) { day in
                                selectedDay = day
                                withAnimation { proxy.scrollTo("day-\(CalFmt.dayKey(day))", anchor: .top) }
                            }
                            .padding(.horizontal, 16).padding(.top, 8)

                            Divider().overlay(Theme.line).padding(.horizontal, 16)

                            if model.loading {
                                ProgressView().tint(Theme.cyan).padding(.top, 30)
                            } else if agenda.isEmpty {
                                emptyState
                            } else {
                                ForEach(agenda, id: \.day) { section in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(CalFmt.dayHeader(section.day))
                                            .font(Theme.label(12, weight: .bold)).tracking(1).foregroundStyle(.black)
                                            .padding(.horizontal, 16)
                                        ForEach(section.items) { slice in
                                            EventCard(slice: slice, model: model, onOpen: { detail = slice.occ })
                                                .padding(.horizontal, 16)
                                        }
                                    }
                                    .id("day-\(CalFmt.dayKey(section.day))")
                                }
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .refreshable { await model.load() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Special Ops", size: 20) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "calendar.badge.plus").foregroundStyle(.black) }
                }
            }
            .task { model.currentMemberId = app.currentMember?.id; await model.start() }
            .onDisappear { model.stop() }
            .sheet(isPresented: $showCreate) { EventEditView(model: model, editing: nil).flyUpSheet() }
            .sheet(item: $editing) { ev in EventEditView(model: model, editing: ev).flyUpSheet() }
            .sheet(item: $detail) { occ in
                EventDetailView(occ: occ, model: model,
                                canManage: occ.event.createdBy == app.currentMember?.id || app.currentMember?.isAdmin == true,
                                onEdit: { detail = nil; editing = occ.event })
                    .flyUpSheet()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 34)).foregroundStyle(.black)
            Text("No upcoming events.").font(Theme.label(15, weight: .bold)).foregroundStyle(.black)
            Text("Tap the calendar icon to add one.").font(Theme.label(13)).foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }
}

// MARK: - Month grid

struct MonthGrid: View {
    @Binding var monthAnchor: Date
    @Binding var selectedDay: Date
    let dotDays: Set<String>
    let spanDays: Set<String>
    let onSelect: (Date) -> Void

    private let cal = CalFmt.central
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").foregroundStyle(.black) }
                Spacer()
                Text(CalFmt.monthTitle(monthAnchor)).font(Theme.label(16, weight: .bold)).foregroundStyle(.black)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").foregroundStyle(.black) }
            }
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { d in
                    Text(d).font(Theme.label(11, weight: .bold)).foregroundStyle(Theme.textDim)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 38) }
                }
            }
        }
        .padding(14)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }

    private func dayCell(_ day: Date) -> some View {
        let key = CalFmt.dayKey(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        let markColor = isSelected ? Theme.onPrimary : Theme.cyan
        let weekday = cal.component(.weekday, from: day)   // 1 = Sun … 7 = Sat
        let covered = spanDays.contains(key)
        let hasDot = dotDays.contains(key)
        // The span line connects to a neighbor only within the same week row.
        let contLeft = covered && weekday != 1 &&
            (cal.date(byAdding: .day, value: -1, to: day).map { spanDays.contains(CalFmt.dayKey($0)) } ?? false)
        let contRight = covered && weekday != 7 &&
            (cal.date(byAdding: .day, value: 1, to: day).map { spanDays.contains(CalFmt.dayKey($0)) } ?? false)
        return Button { onSelect(day) } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(Theme.label(14, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.onPrimary : .black)
                ZStack {
                    if covered {
                        UnevenRoundedRectangle(
                            topLeadingRadius: contLeft ? 0 : 3, bottomLeadingRadius: contLeft ? 0 : 3,
                            bottomTrailingRadius: contRight ? 0 : 3, topTrailingRadius: contRight ? 0 : 3)
                            .fill(markColor)
                            .frame(height: 4)
                            .padding(.leading, contLeft ? 0 : 6)
                            .padding(.trailing, contRight ? 0 : 6)
                    }
                    // A node dot at each day makes the span read as connected.
                    if covered || hasDot {
                        Circle().fill(markColor).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 6)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(isSelected ? Theme.cyan : (isToday ? Theme.surfaceHi : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var days: [Date?] {
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        guard let first = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let leading = cal.component(.weekday, from: first) - 1  // Sunday = 1
        var result: [Date?] = Array(repeating: nil, count: leading)
        for d in range { result.append(cal.date(byAdding: .day, value: d - 1, to: first)) }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: monthAnchor) { monthAnchor = d }
    }
}

// MARK: - Event card (agenda row)

struct EventCard: View {
    let slice: DaySlice
    let model: CalendarModel
    let onOpen: () -> Void
    @Environment(\.openURL) private var openURL

    private var occ: Occurrence { slice.occ }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(occ.event.title).font(Theme.label(16, weight: .bold)).foregroundStyle(.black)
                            .lineLimit(1)
                        if occ.isMultiDay {
                            Text("MULTI-DAY").font(Theme.label(9, weight: .bold)).foregroundStyle(Theme.onPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.cyan).clipShape(Capsule())
                        }
                    }
                    Text(timeText).font(Theme.label(13)).foregroundStyle(.black)
                    if occ.event.hasLocation, let loc = occ.event.location {
                        Button { openInMaps(loc) } label: {
                            Label(loc, systemImage: "mappin.and.ellipse")
                                .font(Theme.label(13, weight: .medium)).foregroundStyle(Theme.cyan).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        if occ.event.recurrence != .none {
                            Label(occ.event.recurrence.shortLabel, systemImage: "repeat")
                                .font(Theme.label(11, weight: .bold)).foregroundStyle(Theme.cyan)
                        }
                        let c = model.counts(occ)
                        Text("✓ \(c.yes)   ✗ \(c.no)   ? \(c.maybe)")
                            .font(Theme.label(12, weight: .bold)).foregroundStyle(.black)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.black)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }

            // RSVP once, on the event's starting day.
            if slice.isStart {
                HStack(spacing: 8) {
                    ForEach(RSVPStatus.allCases, id: \.self) { status in
                        let mine = model.myStatus(occ) == status
                        Button { Task { await model.setRSVP(occ, status) } } label: {
                            Text(status.label)
                                .font(Theme.label(13, weight: .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(mine ? color(status) : Theme.surfaceHi)
                                .foregroundStyle(mine ? Theme.onPrimary : .black)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(color(status).opacity(mine ? 1 : 0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }

    // "5:00 PM – 8:00 PM" for a single day; for a multi-day event, per-day context.
    private var timeText: String {
        if !occ.isMultiDay { return "\(CalFmt.time(occ.start)) – \(CalFmt.time(occ.end))" }
        if slice.isStart { return "Starts \(CalFmt.time(occ.start)) · ends \(CalFmt.shortDate(occ.end))" }
        if slice.isEnd { return "Ends \(CalFmt.time(occ.end))" }
        return "All day"
    }

    private func openInMaps(_ location: String) {
        let q = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(q)") { openURL(url) }
    }

    private func color(_ s: RSVPStatus) -> Color {
        switch s { case .yes: return Theme.cyan; case .no: return Theme.red; case .maybe: return Avatars.badgeGreen }
    }
}

// Renders event notes: bullet lines (- / * / •) get a hanging bullet, blank
// lines become spacing, everything else is a readable paragraph.
struct EventNotesView: View {
    let text: String

    private struct Line: Identifiable { let id: Int; let raw: String }
    private var lines: [Line] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .enumerated().map { Line(id: $0.offset, raw: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines) { line in
                let trimmed = line.raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Color.clear.frame(height: 2)
                } else if let bullet = bulletBody(trimmed) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Theme.label(15, weight: .bold)).foregroundStyle(Theme.cyan)
                        Text(bullet).font(Theme.label(15)).foregroundStyle(.black)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text(line.raw).font(Theme.label(15)).foregroundStyle(.black)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
        }
    }

    // Returns the text after a leading bullet marker, or nil if the line isn't a bullet.
    private func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "– "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }
}

// MARK: - Event detail

struct EventDetailView: View {
    let occ: Occurrence
    let model: CalendarModel
    let canManage: Bool
    let onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(occ.event.title).font(Theme.label(20, weight: .heavy)).foregroundStyle(.black)
                                    Spacer()
                                    if canManage {
                                        Button { onEdit() } label: {
                                            Image(systemName: "pencil").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                                        }
                                        .accessibilityLabel("Edit event")
                                    }
                                }
                                Label(dateLine, systemImage: "clock").font(Theme.label(14)).foregroundStyle(.black)
                                if occ.event.recurrence != .none {
                                    Label(occ.event.recurrence.label, systemImage: "repeat").font(Theme.label(13)).foregroundStyle(.black)
                                }
                                if occ.event.hasLocation, let loc = occ.event.location {
                                    Button { openInMaps(loc) } label: {
                                        Label(loc, systemImage: "mappin.and.ellipse")
                                            .font(Theme.label(14, weight: .medium)).foregroundStyle(Theme.cyan)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Text("Added by \(occ.event.creatorName)").font(Theme.label(12)).foregroundStyle(Theme.textDim)
                            }
                        }

                        if let desc = occ.event.description, !desc.isEmpty {
                            FieldPanel {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("EVENT NOTES").font(Theme.label(12, weight: .bold)).tracking(1).foregroundStyle(.black)
                                    EventNotesView(text: desc)
                                }
                            }
                        }

                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("YOUR RSVP").font(Theme.label(12, weight: .bold)).tracking(1).foregroundStyle(.black)
                                HStack(spacing: 8) {
                                    ForEach(RSVPStatus.allCases, id: \.self) { status in
                                        let mine = model.myStatus(occ) == status
                                        Button { Task { await model.setRSVP(occ, status) } } label: {
                                            Text(status.label)
                                                .font(Theme.label(13, weight: .bold))
                                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                                .background(mine ? color(status) : Theme.surfaceHi)
                                                .foregroundStyle(mine ? Theme.onPrimary : .black)
                                                .clipShape(Capsule())
                                                .overlay(Capsule().strokeBorder(color(status).opacity(mine ? 1 : 0.4)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if !model.rsvps(for: occ).isEmpty {
                                    Divider().overlay(Theme.oliveDrab)
                                    Text("ALL RSVPS").font(Theme.label(12, weight: .bold)).tracking(1).foregroundStyle(.black)
                                    rsvpList
                                }
                            }
                        }

                        if canManage {
                            Button("DELETE EVENT") { confirmDelete = true }
                                .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("Special Event", size: 20) }
            }
            .alert("Delete this event?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await model.delete(occ.event); dismiss() } }
            } message: {
                Text(occ.event.recurrence == .none ? "This removes the event and its RSVPs." : "This removes the whole repeating series and its RSVPs.")
            }
        }
    }

    private var dateLine: String {
        if occ.isMultiDay {
            return "\(CalFmt.shortDate(occ.start)), \(CalFmt.time(occ.start)) → \(CalFmt.shortDate(occ.end)), \(CalFmt.time(occ.end))"
        }
        return "\(CalFmt.dayHeader(occ.start).capitalized) · \(CalFmt.time(occ.start)) – \(CalFmt.time(occ.end))"
    }

    private func openInMaps(_ location: String) {
        let q = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(q)") { openURL(url) }
    }

    private var rsvpList: some View {
        let r = model.rsvps(for: occ)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach([RSVPStatus.yes, .maybe, .no], id: \.self) { status in
                let names = r.filter { $0.status == status }.compactMap { $0.member?.displayName }.sorted()
                if !names.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text(badge(status)).font(Theme.label(13, weight: .bold)).foregroundStyle(color(status))
                            .frame(width: 62, alignment: .leading)
                        Text(names.joined(separator: ", ")).font(Theme.label(14)).foregroundStyle(.black)
                        Spacer()
                    }
                }
            }
        }
    }

    private func badge(_ s: RSVPStatus) -> String {
        switch s { case .yes: return "Going"; case .no: return "Can't"; case .maybe: return "Maybe" }
    }
    private func color(_ s: RSVPStatus) -> Color {
        switch s { case .yes: return Theme.cyan; case .no: return Theme.red; case .maybe: return Avatars.badgeGreen }
    }
}

// MARK: - Create / edit

struct EventEditView: View {
    let model: CalendarModel
    let editing: CalEvent?
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var location = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var recurrence: Recurrence = .none
    @State private var hasUntil = false
    @State private var until = Date().addingTimeInterval(60 * 86400)
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                fieldLabel("TITLE")
                                inputField($title)
                                fieldLabel("LOCATION")
                                inputField($location)
                                fieldLabel("EVENT NOTES")
                                Text("Start a line with “- ” for bullet points.")
                                    .font(Theme.label(11)).foregroundStyle(Theme.textDim)
                                TextEditor(text: $description)
                                    .frame(minHeight: 160).scrollContentBackground(.hidden)
                                    .padding(8).background(Theme.surfaceHi)
                                    .foregroundStyle(Theme.textPrimary)
                                    .font(Theme.label(15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                            }
                        }
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                DatePicker("Starts", selection: $start).tint(Theme.cyan)
                                    .foregroundStyle(.black).font(Theme.label(15))
                                    .onChange(of: start) { _, s in if end < s { end = s.addingTimeInterval(3600) } }
                                DatePicker("Ends", selection: $end, in: start...).tint(Theme.cyan)
                                    .foregroundStyle(.black).font(Theme.label(15))
                                Divider().overlay(Theme.oliveDrab)
                                Picker("Repeat", selection: $recurrence) {
                                    ForEach(Recurrence.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .tint(Theme.cyan).font(Theme.label(15))
                                if recurrence != .none {
                                    Toggle("End repeat on a date", isOn: $hasUntil).tint(Theme.cyan)
                                        .font(Theme.label(15)).foregroundStyle(.black)
                                    if hasUntil {
                                        DatePicker("Until", selection: $until, in: start..., displayedComponents: .date)
                                            .tint(Theme.cyan).foregroundStyle(.black).font(Theme.label(15))
                                    }
                                }
                            }
                        }
                        if let e = errorText { Text(e).font(Theme.label(13)).foregroundStyle(Theme.red) }

                        Button { save() } label: {
                            if working { ProgressView().tint(.black) } else { Text(editing == nil ? "CREATE EVENT" : "SAVE CHANGES") }
                        }
                        .buttonStyle(JoeButtonStyle())
                        .disabled(working || title.trimmed.isEmpty)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle(editing == nil ? "New Event" : "Edit Event", size: 20) } }
            .onAppear(perform: prime)
        }
    }

    private func prime() {
        guard let e = editing else { return }
        title = e.title
        description = e.description ?? ""
        location = e.location ?? ""
        start = e.startsAt
        end = e.endsAt
        recurrence = e.recurrence
        if let u = e.recurrenceUntil { hasUntil = true; until = u }
    }

    private func save() {
        guard let me = app.currentMember?.id else { return }
        errorText = nil
        working = true
        let untilStr = (recurrence != .none && hasUntil) ? CalFmt.dayKey(until) : nil
        Task {
            do {
                if let e = editing {
                    try await TriviaService.updateEvent(id: e.id, title: title.trimmed, description: description, location: location.trimmed,
                                                        startsAt: start, endsAt: end, recurrence: recurrence, recurrenceUntil: untilStr)
                } else {
                    try await TriviaService.createEvent(createdBy: me, title: title.trimmed, description: description, location: location.trimmed,
                                                        startsAt: start, endsAt: end, recurrence: recurrence, recurrenceUntil: untilStr)
                }
                await model.load()
                dismiss()
            } catch {
                errorText = "Couldn't save the event."
            }
            working = false
        }
    }
}
