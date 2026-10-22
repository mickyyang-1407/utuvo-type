import Foundation
import UTUVOTypeCore

/// Final output policy: selected language variant → deterministic cleanup →
/// exact personal spellings and CJK/Latin spacing. Technical literals stay intact.
struct TextPipeline: Sendable {
    private let normalizer: Normalizer
    private let dictionary: [String: String]
    private let taiwan: Bool

    init(dictionary: [String: String] = DictionaryStore.shared.dictionary,
         latinTerms: [String] = VocabularyPacks.latinTermsForFixer(),
         language: String = "zh-TW", variant: LanguageVariant = .none) {
        self.dictionary = dictionary
        self.taiwan = LanguageVariant.traditionalFixerTarget(variant: variant, language: language)
        self.normalizer = Normalizer(options: NormalizerOptions(
            dictionary: [:], fillerSet: NormalizerOptions.defaultFillers,
            localeIdentifier: language, latinTerms: latinTerms))
    }

    static func regional(_ text: String, taiwan: Bool,
                         normalize: (String, Bool) -> String = { text, tw in tw ? TraditionalFixer.shared.fix(text) : text }) -> String {
        let converted = normalize(text, taiwan)
        return taiwan ? TaiwanPlaces.fixStations(TaiwanPhrases.apply(converted)) : converted
    }

    /// Recognizers/models may already have normalized a name (臺→台, 三點→3:00).
    /// Those aliases restore the user's explicit spelling, never replace an explicit rule.
    static func aliases(_ dictionary: [String: String], regional: (String) -> String) -> [String: String] {
        var result = dictionary
        for source in dictionary.keys.sorted() {
            let target = dictionary[source].flatMap { $0.isEmpty ? nil : $0 } ?? source
            for value in [source, target] {
                let converted = regional(value)
                let hasNumber = converted.contains { $0.isNumber || "零〇一二三四五六七八九十百千萬億兩两".contains($0) }
                let variants = hasNumber ? [converted, Normalizer.normalizeNumbers(converted)] : [converted]
                for alias in variants where !alias.isEmpty && result[alias] == nil {
                    result[alias] = target
                }
            }
        }
        return result
    }

    /// Compare in the selected regional vocabulary and the same user dictionary.
    /// Do not remove substantive words or run filler/self-correction heuristics here.
    static func validationText(_ text: String, taiwan: Bool, dictionary: [String: String],
                               normalize: (String, Bool) -> String) -> String {
        let replacements = aliases(dictionary) { regional($0, taiwan: taiwan, normalize: normalize) }
        return TextPresentation.format(text, dictionary: replacements) {
            Normalizer.normalizeNumbers(regional($0, taiwan: taiwan, normalize: normalize))
        }
    }

    func clean(_ transcript: String) -> (output: String, steps: [String]) {
        var steps: [String] = []
        let region = { Self.regional($0, taiwan: taiwan) }
        let output = TextPresentation.format(transcript, dictionary: Self.aliases(dictionary, regional: region)) { masked in
            let localized = region(masked)
            if localized != masked { steps.append("taiwan-phrases") }
            let result = normalizer.normalize(localized)
            steps += result.appliedSteps
            return result.cleaned
        }
        if !dictionary.isEmpty { steps.append("dictionary") }
        steps.append("mixed-script-spacing")
        return (output, steps)
    }
}
