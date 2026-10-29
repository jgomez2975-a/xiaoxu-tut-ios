//
//  ImagePicker.swift
//  NpcLab
//
//  相机拍照。相册走 SwiftUI 原生的 PhotosPicker（在 ChatView 里直接用），
//  只有相机还得包一层 UIKit —— 到 iOS 17 都没有 SwiftUI 版。
//
//  权限：Info.plist 里 NSCameraUsageDescription 已填（Setting → 权限 里能看到）。
//  用户拒了相机权限时 picker 会直接弹系统提示，不崩。
//

import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {

    /// 拍完回调。取消时传 nil。
    var onShot: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        // 模拟器上没有相机，退到相册，免得白屏
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.allowsEditing = false
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ ui: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                  didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = info[.originalImage] as? UIImage
            parent.onShot(img)
            // 自己关自己。这里的 parent 是 representable，拿不到 SwiftUI 的 dismiss，
            // 由 ChatView 那边把 isPresented 置 false 也可以，但双保险更稳。
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onShot(nil)
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 缩略图

/// 输入框上方那条附件预览。点一下放大，长按删。
struct AttachmentStrip: View {

    var names: [String]
    var onRemove: (String) -> Void
    var onPreview: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { n in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let img = Attachment.image(n) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                ZStack {
                                    T.card
                                    Image(systemName: "photo")
                                        .foregroundColor(T.txt3)
                                }
                            }
                        }
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(T.line, lineWidth: 1)
                        )
                        .onTapGesture { onPreview(n) }

                        Button {
                            onRemove(n)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// 点图放大看
struct ImageViewer: View {
    var name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = Attachment.image(name) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("图没了（可能被清理过）")
                        .font(.system(size: 13))
                        .foregroundColor(T.txt2)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
