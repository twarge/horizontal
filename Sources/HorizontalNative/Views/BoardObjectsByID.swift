import Foundation

extension BoardContentMemo {
    /// The object of `objects` that `id` names, whatever its case: the first
    /// of that id, as `first(where:)` finds it, from an index of them by id
    /// kept under `name` while they are unchanged. The inspector asks for
    /// each object of the selection in turn, and again after every edit; a
    /// search of all of them for each made that grow with the square of the
    /// selection, 0.7 s after each move of 1,600 selected parts (Debug).
    func object<Object: Identifiable & Equatable>(
        _ id: String,
        in objects: [Object],
        _ name: String
    ) -> Object? where Object.ID == String {
        value("objects by id: \(name)", input: objects) {
            var index = [String: Object](minimumCapacity: objects.count)
            for object in objects {
                let key = HorizontalCanvasModeSupport.normalizedID(object.id)
                if index[key] == nil {
                    index[key] = object
                }
            }
            return index
        }[HorizontalCanvasModeSupport.normalizedID(id)]
    }
}
