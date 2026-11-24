import io, re

p = 'ios/RootView.swift'
s = io.open(p, encoding='utf-8').read()

start = s.index('struct DeviceTab: View {')
end = s.index('/// Sheet version of the device page, so any tab can open the connection UI without leaving.')
new = '''struct DeviceTab: View {
    @ObservedObject var g: Glasses

    var body: some View {
        NavigationStack {
            DeviceTabBody(g: g)
                .navigationTitle("设备")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { StatusCapsule(g: g) {} }
                }
        }
    }
}

'''
s = s[:start] + new + s[end:]
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ok', len(s))
