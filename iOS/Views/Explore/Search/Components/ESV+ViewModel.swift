//
//  ESV+ViewModel.swift
//  Suwatte
//
//  Created by Mantton on 2022-03-07.
//
import Combine

extension ExploreView.SearchView {
    final class ViewModel: ObservableObject {
        @Published var request: DaisukeEngine.Structs.SearchRequest
        @Published var query = ""
        @Published var result = Loadable<[DaisukeEngine.Structs.Highlight]>.idle
        @Published var config: DSKCommon.DirectoryConfig?
        @Published var resultCount: Int?
        @Published var presentFilters = false
        @Published var callFromHistory = false

        var source: AnyContentSource

        private var cancellables = Set<AnyCancellable>()

        enum PaginationStatus: Equatable {
            case LOADING, END, ERROR(error: Error), IDLE

            static func == (lhs: Self, rhs: Self) -> Bool {
                switch (lhs, rhs) {
                case (.LOADING, .LOADING): return true
                case (.END, .END): return true
                case (.IDLE, .IDLE): return true
                case let (.ERROR(error: lhsE), .ERROR(error: rhsE)):
                    return lhsE.localizedDescription == rhsE.localizedDescription
                default: return false
                }
            }
        }
        
        var sortOptions: [DSKCommon.SortOption] {
            config?.sortOptions ?? []
        }
        
        var filters: [DSKCommon.Filter] {
            config?.filters ?? []
        }

        @Published var paginationStatus = PaginationStatus.IDLE

        init(request: DaisukeEngine.Structs.SearchRequest = .init(), source: AnyContentSource) {
            self.request = request
            self.source = source
            self.fetchConfig()
            fetchConfig()
        }
        
        func fetchConfig() {
            Task {
                do {
                    self.config = try await source.getDirectoryConfig()
                } catch {
                    Logger.shared.error(error)
                    ToastManager.shared.error(error)
                }
            }
        }

        func softReset() {
            request = .init()
            request.page = 1
            request.query = nil
            request.sort = config?.sortOptions?.first?.id
        }

        func makeRequest() async {
            await MainActor.run(body: {
                result = .loading
            })
            do {
                let data = try await source.getDirectory(request)

                await MainActor.run(body: {
                    self.result = .loaded(data.results)
                    self.resultCount = data.totalResultCount
                })

            } catch {
                await MainActor.run(body: {
                    self.result = .failed(error)
                })
            }
        }

        func paginate() async {
            switch paginationStatus {
            case .IDLE, .ERROR:
                break
            default: return
            }

            await MainActor.run(body: {
                request.page? += 1
                paginationStatus = .LOADING
            })

            do {
                let response = try await source.getDirectory(request)
                if response.results.isEmpty {
                    await MainActor.run(body: {
                        self.paginationStatus = .END
                    })
                    return
                }

                await MainActor.run(body: {
                    var currentEntries = self.result.value ?? []
                    currentEntries.append(contentsOf: response.results)
                    self.result = .loaded(currentEntries)
                    if response.isLastPage {
                        self.paginationStatus = .END
                        return
                    }

                    self.paginationStatus = .IDLE
                })

            } catch {
                await MainActor.run(body: {
                    self.paginationStatus = .ERROR(error: error)
                    self.request.page? -= 1
                })
            }
        }
    }
}
