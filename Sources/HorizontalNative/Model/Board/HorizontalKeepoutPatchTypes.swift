extension HorizontalKeepout {
    /// The kinds of copper a keepout can bar, as Horizon's `patch_types_cu`
    /// spells them and in the order the keepout's details list them.
    static let patchTypeIDs = ["track", "pad", "pad_th", "via", "plane", "text", "net_tie", "hole_pth", "hole_npth"]

    /// What a keepout bars when nothing says otherwise, as a package's
    /// keepout starts: the board's copper and its plated holes.
    static let defaultPatchTypes = ["track", "pad", "pad_th", "via", "plane", "hole_pth"]
}
