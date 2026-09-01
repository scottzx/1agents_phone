//
//  AlphabetHelper.swift
//  Minis
//
//  Helper for Chinese pinyin conversion, letter section extraction,
//  and alphabetical sorting (A-Z, #).
//

import Foundation

enum AlphabetHelper {
    /// Extracts the A-Z uppercase section key for a given string.
    /// Non-ASCII/non-Latin characters (e.g. Chinese characters) are converted to pinyin.
    /// Strings starting with numbers or symbols are grouped under "#".
    static func pinyinSectionKey(for string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstChar = trimmed.first else { return "#" }
        
        let firstStr = String(firstChar)
        let mutable = NSMutableString(string: firstStr) as CFMutableString
        
        // Transform Chinese characters to Latin pinyin
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        // Strip diacritics / tones (e.g., "ā" -> "a")
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        
        let result = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let firstAlpha = result.first, firstAlpha >= "A", firstAlpha <= "Z" else {
            return "#"
        }
        return String(firstAlpha)
    }
    
    /// Compares two strings using localized pinyin/alphabetical collation.
    static func alphabeticalCompare(_ s1: String, _ s2: String) -> Bool {
        let key1 = pinyinSectionKey(for: s1)
        let key2 = pinyinSectionKey(for: s2)
        
        // Put '#' at the end
        if key1 == "#" && key2 != "#" {
            return false
        }
        if key1 != "#" && key2 == "#" {
            return true
        }
        
        // If keys differ, sort by key
        if key1 != key2 {
            return key1 < key2
        }
        
        // Otherwise compare standard localized string
        return s1.localizedStandardCompare(s2) == .orderedAscending
    }
    
    /// Sorts an array of items alphabetically by a specific string keypath.
    static func sortedByAlphabet<T>(_ items: [T], by keyPath: KeyPath<T, String>) -> [T] {
        items.sorted { lhs, rhs in
            alphabeticalCompare(lhs[keyPath: keyPath], rhs[keyPath: keyPath])
        }
    }
}
