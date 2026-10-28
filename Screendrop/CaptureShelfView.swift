//
//  CaptureShelfView.swift
//  Screendrop
//
//  The floating preview's content: a column of 150 × 150 squares, newest at
//  the top, bottom-anchored in the chosen screen corner. Dragging the stack
//  moves the whole column; each square keeps its own controls.
//

import SwiftUI

struct CaptureShelfView: View {
    @State private var shelf = CaptureShelf.shared
    private let presenter = CaptureShelfPresenter.shared

    private var tile: CGSize { PreviewCardMetrics.tileSize }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !shelf.isTucked {
                VStack(spacing: PreviewCardMetrics.tileSpacing) {
                    ForEach(shelf.items) { item in
                        CaptureShelfCard(item: item, shelf: shelf)
                            .frame(width: tile.width, height: tile.height)
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.92, anchor: .bottom)
                                        .combined(with: .opacity),
                                    removal: .offset(x: 76, y: 0)
                                        .combined(with: .opacity)
                                )
                            )
                            .id(item.id)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: shelf.items.count) { _, _ in
            presenter.refreshCardSize()
        }
        // A recording's real thumbnail replaces its placeholder once the
        // package is ready.
        .onChange(of: shelf.items.first?.thumbnail.size) { _, _ in
            presenter.refreshCardSize()
        }
        .onChange(of: shelf.isTucked) { _, isTucked in
            presenter.setTucked(isTucked)
        }
    }
}
