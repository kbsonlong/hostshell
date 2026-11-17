import Foundation

public enum ShellProvider: String, CaseIterable, Sendable {
    case zsh, bash, fish

    public static func detect(executable: String) -> ShellProvider? {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        return allCases.first { $0.rawValue == name }
    }

    public var script: String {
        switch self { case .zsh: return Self.zshScript; case .bash: return Self.bashScript; case .fish: return Self.fishScript }
    }

    public var installSnippet: String { "# HostShell completion provider v1\n" + script }

    private static let zshScript = #"""
# HostShell completion provider v1
if [[ -o interactive && -n "${HOSTSHELL_COMPLETION-}" && -z "${HOSTSHELL_COMPLETION_PROVIDER_ACTIVE-}" ]]; then
  export HOSTSHELL_COMPLETION_PROVIDER_ACTIVE=1
  _hostshell_emit() {
    local line=$BUFFER cursor=$CURSOR
    [[ ${#line} -le 16384 && $cursor -ge 0 && $cursor -le ${#line} ]] || return 0
    printf '\033]777;hostshell.completion;{"line":"%s","cursor":%d,"interactive":true,"candidates":[]}\007' "$line" "$cursor"
  }
  _hostshell_widget() { _hostshell_emit; zle self-insert; }
  zle -N _hostshell_widget
  bindkey '^I' _hostshell_widget
fi
"""#

    private static let bashScript = #"""
# HostShell completion provider v1
if [[ $- == *i* && -n ${HOSTSHELL_COMPLETION-} && -z ${HOSTSHELL_COMPLETION_PROVIDER_ACTIVE-} ]]; then
  export HOSTSHELL_COMPLETION_PROVIDER_ACTIVE=1
  _hostshell_emit() {
    local line=$READLINE_LINE cursor=$READLINE_POINT
    [[ ${#line} -le 16384 && $cursor -ge 0 && $cursor -le ${#line} ]] || return 0
    printf '\033]777;hostshell.completion;{"line":"%s","cursor":%d,"interactive":true,"candidates":[]}\007' "$line" "$cursor"
  }
  _hostshell_widget() { _hostshell_emit; }
  bind -x '"\C-i":_hostshell_widget'
fi
"""#

    private static let fishScript = #"""
# HostShell completion provider v1
if status is-interactive; and set -q HOSTSHELL_COMPLETION; and not set -q HOSTSHELL_COMPLETION_PROVIDER_ACTIVE
  set -gx HOSTSHELL_COMPLETION_PROVIDER_ACTIVE 1
  function _hostshell_emit
    set -l line (commandline)
    set -l cursor (commandline -C)
    if test (string length -- $line) -le 16384
      printf '\e]777;hostshell.completion;{"line":"%s","cursor":%d,"interactive":true,"candidates":[]}\a' "$line" $cursor
    end
  end
  function _hostshell_widget
    _hostshell_emit
    commandline -f self-insert
  end
  bind \cI _hostshell_widget
end
"""#
}

public extension ShellProvider {
    static var optInEnvironment: [String: String] {
        ["HOSTSHELL_COMPLETION": "1", "HOSTSHELL_COMPLETION_PROTOCOL": "osc777", "HOSTSHELL_COMPLETION_PROVIDER_VERSION": "1"]
    }
}
