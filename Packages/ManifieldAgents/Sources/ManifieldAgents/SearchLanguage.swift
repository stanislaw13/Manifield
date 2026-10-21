import Foundation
import ManifieldCore

/// Puts the language of a searchable corpus in front of the agent.
///
/// The failure this prevents is silent: chatting in English about a Polish paper, the
/// agent searches for "compact connected", gets nothing back, and reports that the source
/// does not discuss the theorem — when it does, under `zwarty spójny`. FTS matching is
/// literal, so every search surface names the language of what it indexes: in the tool
/// description (before the query is written) and again in an empty result (where the
/// mistake actually shows).
enum SearchLanguage {

    /// A corpus the agent can query, paired with the language it is written in.
    struct Corpus {
        let label: String
        let language: LanguageDetection.Language?

        init(label: String, language: LanguageDetection.Language?) {
            self.label = label
            self.language = language
        }
    }

    /// "slug [Polish]" — the language tag is dropped when detection was inconclusive
    /// (too little prose, or a corpus that is mostly formulas).
    static func listing(_ corpora: [Corpus]) -> String {
        corpora
            .map { corpus in
                guard let language = corpus.language else { return corpus.label }
                return "\(corpus.label) [\(language.name)]"
            }
            .joined(separator: ", ")
    }

    /// Appended to a search tool's description, so the language is known before the query
    /// is written rather than after it comes back empty.
    static func rule(_ corpora: [Corpus]) -> String {
        let named = corpora.compactMap(\.language)
        guard !named.isEmpty else { return "" }
        let languages = Set(named.map(\.name)).sorted()
        var rule = " Write the query in the language of the text you are searching"
        if languages.count == 1 {
            rule += " — \(languages[0]) here, whatever language this conversation is in."
        } else {
            rule += " (\(languages.joined(separator: ", ")) here, whatever language this"
                + " conversation is in); search once per language when several apply."
        }
        return rule + " Matching is literal: translated terms find nothing."
    }

    /// Appended to an empty result set — the moment the agent is about to conclude the
    /// text says nothing on the subject.
    static func emptyHint(_ corpora: [Corpus]) -> String {
        let described = corpora.compactMap { corpus -> String? in
            guard let language = corpus.language else { return nil }
            return "\(corpus.label) is written in \(language.name)"
        }
        guard !described.isEmpty else { return "" }
        return " \(described.joined(separator: ", ")) — matching is literal, so if your"
            + " terms are not in that language, translate them (keep names and symbols as"
            + " written) and search again before concluding anything is missing."
    }
}
