import SwiftUI
import PhotosUI
 
struct ContentView: View {
    @State private var camera = CameraModel()
 
    var body: some View {
        @Bindable var camera = camera
 
        ZStack {
            CameraPreview(camera: camera)
                .ignoresSafeArea(.all, edges: .all)
                .overlay {
                    if camera.isTaken, let image = UIImage(data: camera.picData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                    }
                }
                .clipped()
 
            VStack {
                if camera.isTaken {
                    Text("Photo \(camera.capturedPhotos.count + 1)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
 
                Spacer()
 
                if camera.isTaken {
                    reviewBar
                } else {
                    HStack {
                        PhotosPicker(selection: $camera.picDataPicker, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .offset(x: 10)
                        }
 
                        Spacer()
 
                        Button(action: camera.takePicture) {
                            ZStack {
                                Circle().fill(Color.white).frame(width: 65, height: 65)
                                Circle().stroke(Color.white, lineWidth: 2).frame(width: 70, height: 70)
                            }
                        }
                        .offset(x: -15)
 
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .frame(height: 75)
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $camera.showResults, onDismiss: { camera.finishResults() }) {
            PhotoTextResultsView(items: camera.photoTexts)
        }
        .overlay {
            if camera.isRecognizing {
                ProgressView("Reading text…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
 
    // MARK: Review bar (shown after a photo is taken)
 
    private var reviewBar: some View {
        HStack {
            BarButton(systemName: "xmark", label: "Cancel") { camera.cancelAll() }
            Spacer()
            BarButton(systemName: "arrow.counterclockwise", label: "Retake") { camera.retakePicture() }
            Spacer()
            BarButton(systemName: "arrow.right", label: "Next photo") { camera.nextPicture() }
            Spacer()
            BarButton(systemName: "checkmark", label: "Done") { camera.done() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
 
private struct BarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
 
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel(label)
    }
}
 
#Preview {
    ContentView()
}
 

