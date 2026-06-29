/// The released version of the DeepAgents framework, exposed so host front-ends can report which
/// framework build they were compiled against - the Ripple CLI's `--version` and the Mispher app's
/// About pane both read this. Kept in sync with the `deepagents-swift` git tag cut by
/// `scripts/publish-mirrors.sh`.
public enum DeepAgentsVersion {
    /// Semantic version string, e.g. "0.2.3".
    public static let current = "0.2.4"
}
