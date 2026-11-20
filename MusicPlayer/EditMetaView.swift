import SwiftUI

/// 编辑歌曲信息（对齐安卓 EditMetaScreen）：标题/歌手/专辑/词曲/年月/歌词。
struct EditMetaView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var writerLyric: String
    @State private var writerMusic: String
    @State private var releaseYm: String
    @State private var lrcText: String = ""
    @State private var saved = false

    init(song: Song) {
        self.song = song
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _writerLyric = State(initialValue: song.writerLyric ?? "")
        _writerMusic = State(initialValue: song.writerMusic ?? "")
        _releaseYm = State(initialValue: song.releaseYm ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("歌曲信息")) {
                    field("标题", $title)
                    field("歌手", $artist)
                    field("专辑", $album)
                    field("作词", $writerLyric)
                    field("作曲", $writerMusic)
                    field("发行年月", $releaseYm)
                }
                Section(header: Text("歌词（LRC 时间轴）"), footer: Text("每行形如 [00:12.34]歌词。留空表示清除歌词。")) {
                    TextEditor(text: $lrcText)
                        .font(.system(size: 13))
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("编辑歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                }
            }
            .onAppear { lrcText = LrcParser.rawText(for: song) ?? "" }
            .alert("已保存", isPresented: $saved) {
                Button("好") { dismiss() }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Theme.accent)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(Theme.text2).frame(width: 70, alignment: .leading)
            TextField(label, text: text).foregroundColor(Theme.text)
        }
    }

    private func save() {
        var s = song
        s.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        s.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        s.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        s.writerLyric = writerLyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : writerLyric
        s.writerMusic = writerMusic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : writerMusic
        s.releaseYm = releaseYm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : releaseYm
        library.update(s, lrcText: lrcText)
        saved = true
    }
}
