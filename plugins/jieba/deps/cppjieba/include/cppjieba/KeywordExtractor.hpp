#ifndef CPPJIEBA_KEYWORD_EXTRACTOR_H
#define CPPJIEBA_KEYWORD_EXTRACTOR_H

#include <algorithm>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include "MixSegment.hpp"
#include "UnicodeFile.hpp"

namespace cppjieba {

/*utf8*/
class KeywordExtractor {
 public:
  struct Word {
    std::string word;
    std::vector<size_t> offsets;
    double weight;
  }; // struct Word

  KeywordExtractor(const std::string& dictPath,
        const std::string& hmmFilePath,
        const std::string& idfPath,
        const std::string& stopWordPath,
        const std::string& userDict = "")
    : segment_(dictPath, hmmFilePath, userDict),
      idfAverage_(0.0) {
    LoadIdfDict(idfPath);
    LoadStopWordDict(stopWordPath);
  }
  KeywordExtractor(const DictTrie* dictTrie,
        const HMMModel* model,
        const std::string& idfPath,
        const std::string& stopWordPath)
    : segment_(dictTrie, model),
      idfAverage_(0.0) {
    LoadIdfDict(idfPath);
    LoadStopWordDict(stopWordPath);
  }
  // ========== OPENCC_MOD: 内存版 KeywordExtractor (start) ==========
  KeywordExtractor(const DictTrie* dictTrie,
        const HMMModel* model,
        const char* idfData,
        size_t idfSize,
        const char* stopWordData,
        size_t stopWordSize)
    : segment_(dictTrie, model),
      idfAverage_(0.0) {
    LoadIdfDictFromBuffer(idfData, idfSize);
    LoadStopWordDictFromBuffer(stopWordData, stopWordSize);
  }
  // ========== OPENCC_MOD: end ==========
  ~KeywordExtractor() {
  }

  void Extract(const std::string& sentence, std::vector<std::string>& keywords, size_t topN) const {
    std::vector<Word> topWords;
    Extract(sentence, topWords, topN);
    for (size_t i = 0; i < topWords.size(); i++) {
      keywords.push_back(topWords[i].word);
    }
  }

  void Extract(const std::string& sentence, std::vector<pair<std::string, double> >& keywords, size_t topN) const {
    std::vector<Word> topWords;
    Extract(sentence, topWords, topN);
    for (size_t i = 0; i < topWords.size(); i++) {
      keywords.push_back(pair<std::string, double>(topWords[i].word, topWords[i].weight));
    }
  }

  void Extract(const std::string& sentence, std::vector<Word>& keywords, size_t topN) const {
    // ========== OPENCC_MOD: 空词典跳过关键词提取 (start) ==========
    // idf 词典或停用词词典缺失时，关键词提取退化为基础分词统计。
    // 分词功能不受影响，但关键词权重将不准确。
    // ========== OPENCC_MOD: end ==========
    std::vector<std::string> words;
    segment_.Cut(sentence, words);

    std::map<std::string, Word> wordmap;
    size_t offset = 0;
    for (size_t i = 0; i < words.size(); ++i) {
      size_t t = offset;
      offset += words[i].size();
      if (IsSingleWord(words[i]) || stopWords_.find(words[i]) != stopWords_.end()) {
        continue;
      }
      wordmap[words[i]].offsets.push_back(t);
      wordmap[words[i]].weight += 1.0;
    }
    if (offset != sentence.size()) {
      XLOG(ERROR) << "words illegal";
      return;
    }

    keywords.clear();
    keywords.reserve(wordmap.size());
    for (std::map<std::string, Word>::iterator itr = wordmap.begin(); itr != wordmap.end(); ++itr) {
      std::unordered_map<std::string, double>::const_iterator cit = idfMap_.find(itr->first);
      if (cit != idfMap_.end()) {
        itr->second.weight *= cit->second;
      } else {
        itr->second.weight *= idfAverage_;
      }
      itr->second.word = itr->first;
      keywords.push_back(itr->second);
    }
    topN = min(topN, keywords.size());
    std::partial_sort(keywords.begin(), keywords.begin() + topN, keywords.end(), Compare);
    keywords.resize(topN);
  }
 private:
  void LoadIdfDict(const std::string& idfPath) {
    // ========== OPENCC_MOD: 空路径跳过加载，关键词提取不可用但分词正常 (start) ==========
    if (idfPath.empty()) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
    std::ifstream ifs;
    OpenInputFile(ifs, idfPath);
    XCHECK(ifs.is_open()) << "open " << idfPath << " failed";
    std::string line ;
    std::vector<std::string> buf;
    double idf = 0.0;
    double idfSum = 0.0;
    size_t lineno = 0;
    for (; getline(ifs, line); lineno++) {
      buf.clear();
      if (line.empty()) {
        XLOG(ERROR) << "lineno: " << lineno << " empty. skipped.";
        continue;
      }
      Split(line, buf, " ");
      if (buf.size() != 2) {
        XLOG(ERROR) << "line: " << line << ", lineno: " << lineno << " empty. skipped.";
        continue;
      }
      idf = atof(buf[1].c_str());
      idfMap_[buf[0]] = idf;
      idfSum += idf;

    }

    // ========== OPENCC_MOD: 无有效条目时静默降级，不崩溃不除零 (start) ==========
    if (lineno == 0) {
      idfAverage_ = 0.0;
      return;
    }
    // ========== OPENCC_MOD: end ==========
    idfAverage_ = idfSum / lineno;
  }
  void LoadStopWordDict(const std::string& filePath) {
    // ========== OPENCC_MOD: 空路径跳过加载，关键词提取不可用但分词正常 (start) ==========
    if (filePath.empty()) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
    std::ifstream ifs;
    OpenInputFile(ifs, filePath);
    XCHECK(ifs.is_open()) << "open " << filePath << " failed";
    std::string line ;
    while (getline(ifs, line)) {
      stopWords_.insert(line);
    }
    // ========== OPENCC_MOD: 无有效条目时静默降级，不崩溃 (start) ==========
    if (stopWords_.empty()) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
  }

  // ========== OPENCC_MOD: 内存版 KeywordExtractor (start) ==========
  void LoadIdfDictFromBuffer(const char* data, size_t size) {
    // ========== OPENCC_MOD: 空 buffer 跳过加载，关键词提取不可用但分词正常 (start) ==========
    if (data == nullptr || size == 0) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
    std::string content(data, size);
    std::istringstream iss(content);
    std::string line;
    std::vector<std::string> buf;
    double idf = 0.0;
    double idfSum = 0.0;
    size_t lineno = 0;
    for (; getline(iss, line); lineno++) {
      buf.clear();
      if (line.empty()) {
        XLOG(ERROR) << "lineno: " << lineno << " empty. skipped.";
        continue;
      }
      Split(line, buf, " ");
      if (buf.size() != 2) {
        XLOG(ERROR) << "line: " << line << ", lineno: " << lineno << " empty. skipped.";
        continue;
      }
      idf = atof(buf[1].c_str());
      idfMap_[buf[0]] = idf;
      idfSum += idf;
    }
    // ========== OPENCC_MOD: 无有效条目时静默降级，不崩溃不除零 (start) ==========
    if (lineno == 0) {
      idfAverage_ = 0.0;
      return;
    }
    // ========== OPENCC_MOD: end ==========
    idfAverage_ = idfSum / lineno;
  }

  void LoadStopWordDictFromBuffer(const char* data, size_t size) {
    // ========== OPENCC_MOD: 空 buffer 跳过加载，关键词提取不可用但分词正常 (start) ==========
    if (data == nullptr || size == 0) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
    std::string content(data, size);
    std::istringstream iss(content);
    std::string line;
    while (getline(iss, line)) {
      if (!line.empty()) {
        stopWords_.insert(line);
      }
    }
    // ========== OPENCC_MOD: 无有效条目时静默降级，不崩溃 (start) ==========
    if (stopWords_.empty()) {
      return;
    }
    // ========== OPENCC_MOD: end ==========
  }
  // ========== OPENCC_MOD: end ==========

  static bool Compare(const Word& lhs, const Word& rhs) {
    return lhs.weight > rhs.weight;
  }

  MixSegment segment_;
  std::unordered_map<std::string, double> idfMap_;
  double idfAverage_;

  std::unordered_set<std::string> stopWords_;
}; // class KeywordExtractor

inline std::ostream& operator << (std::ostream& os, const KeywordExtractor::Word& word) {
  return os << "{\"word\": \"" << word.word << "\", \"offset\": " << word.offsets << ", \"weight\": " << word.weight << "}";
}

} // namespace cppjieba

#endif
