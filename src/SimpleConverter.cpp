/*
 * Open Chinese Convert
 *
 * Copyright 2010-2026 Carbo Kuo and contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstring>

#include "Config.hpp"
#include "Converter.hpp"
#include "Exception.hpp"
#include "UTF8Util.hpp"
#include "opencc.h"
#include <rapidjson/writer.h>
#include <rapidjson/stringbuffer.h>

#ifdef BAZEL
#include "tools/cpp/runfiles/runfiles.h"
using bazel::tools::cpp::runfiles::Runfiles;
#endif

using namespace opencc;

namespace {

struct InternalData {
  const ConverterPtr converter;

  InternalData(const ConverterPtr& _converter) : converter(_converter) {}

  static InternalData* NewInternalData(const std::string& configFileName,
                                       const std::vector<std::string>& paths,
                                       const char* argv0,
                                       const ConfigLoadOptions& options) {
    try {
      Config config;
#ifdef BAZEL
      std::string err;
      std::unique_ptr<Runfiles> bazel_runfiles(
          Runfiles::Create(argv0 != nullptr ? argv0 : "", &err));
      if (bazel_runfiles != nullptr) {
        std::vector<std::string> paths_with_runfiles = paths;
        paths_with_runfiles.push_back(
            bazel_runfiles->Rlocation("opencc~/data/config"));
        paths_with_runfiles.push_back(
            bazel_runfiles->Rlocation("opencc~/data/dictionary"));
        paths_with_runfiles.push_back(
            bazel_runfiles->Rlocation("_main/data/config"));
        paths_with_runfiles.push_back(
            bazel_runfiles->Rlocation("_main/data/dictionary"));
        return new InternalData(
            config.NewFromFile(configFileName, paths_with_runfiles, argv0,
                               options));
      }
#endif
      return new InternalData(
          config.NewFromFile(configFileName, paths, argv0, options));
    } catch (Exception& ex) {
      throw std::runtime_error(ex.what());
    }
  }

  static InternalData* NewInternalData(
      const std::string& configFileName,
      const std::shared_ptr<ResourceProvider>& provider,
      const ConfigLoadOptions& options) {
    try {
      Config config;
      return new InternalData(
          config.NewFromFile(configFileName, provider, options));
    } catch (Exception& ex) {
      throw std::runtime_error(ex.what());
    }
  }
};

// 辅助宏：在 C API 函数中统一捕获所有异常
#define OPENCC_C_API_CATCH_BEGIN try {
#define OPENCC_C_API_CATCH_END(retval) \
  } catch (opencc::Exception& ex) { \
    cError = ex.what(); \
    return retval; \
  } catch (std::runtime_error& ex) { \
    cError = ex.what(); \
    return retval; \
  } catch (std::exception& ex) { \
    cError = ex.what(); \
    return retval; \
  } catch (...) { \
    cError = "Unknown C++ exception"; \
    return retval; \
  }

} // namespace

SimpleConverter::SimpleConverter(const std::string& configFileName)
    : SimpleConverter(configFileName, ConfigLoadOptions()) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 const ConfigLoadOptions& options)
    : SimpleConverter(configFileName, std::vector<std::string>(), options) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 const std::vector<std::string>& paths)
    : SimpleConverter(configFileName, paths, ConfigLoadOptions()) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 const std::vector<std::string>& paths,
                                 const ConfigLoadOptions& options)
    : SimpleConverter(configFileName, paths, nullptr, options) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 const std::vector<std::string>& paths,
                                 const char* argv0)
    : SimpleConverter(configFileName, paths, argv0, ConfigLoadOptions()) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 const std::vector<std::string>& paths,
                                 const char* argv0,
                                 const ConfigLoadOptions& options)
    : internalData(
          InternalData::NewInternalData(configFileName, paths, argv0,
                                        options)) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 std::shared_ptr<ResourceProvider> provider)
    : SimpleConverter(configFileName, provider, ConfigLoadOptions()) {}

SimpleConverter::SimpleConverter(const std::string& configFileName,
                                 std::shared_ptr<ResourceProvider> provider,
                                 const ConfigLoadOptions& options)
    : internalData(
          InternalData::NewInternalData(configFileName, provider, options)) {}

SimpleConverter::~SimpleConverter() { delete (InternalData*)internalData; }

std::string SimpleConverter::Convert(const std::string& input) const {
  return Convert(std::string_view(input));
}

std::string SimpleConverter::Convert(std::string_view input) const {
  try {
    const InternalData* data = (InternalData*)internalData;
    return data->converter->Convert(input);
  } catch (Exception& ex) {
    throw std::runtime_error(ex.what());
  }
}

std::string SimpleConverter::Convert(const char* input) const {
  return Convert(std::string_view(input));
}

std::string SimpleConverter::Convert(const char* input, size_t length) const {
  if (length == static_cast<size_t>(-1)) {
    return Convert(std::string_view(input));
  } else {
    return Convert(std::string_view(input, length));
  }
}

size_t SimpleConverter::Convert(const char* input, char* output) const {
  try {
    const InternalData* data = (InternalData*)internalData;
    const std::string converted = data->converter->Convert(input);
    strcpy(output, converted.c_str());
    return converted.length();
  } catch (Exception& ex) {
    throw std::runtime_error(ex.what());
  }
}

size_t SimpleConverter::Convert(const char* input, size_t length,
                                char* output) const {
  if (length == static_cast<size_t>(-1)) {
    return Convert(input, output);
  } else {
    std::string trimmed = UTF8Util::FromSubstr(input, length);
    return Convert(trimmed.c_str(), output);
  }
}

ConversionInspectionResult
SimpleConverter::Inspect(std::string_view input) const {
  try {
    const InternalData* data = (InternalData*)internalData;
    return data->converter->Inspect(input);
  } catch (Exception& ex) {
    throw std::runtime_error(ex.what());
  }
}

static std::string cError;

// ==================== C API 实现（完整异常捕获）====================

opencc_t opencc_open_internal(const char* configFileName) {
  OPENCC_C_API_CATCH_BEGIN
    if (configFileName == nullptr) {
      configFileName = OPENCC_DEFAULT_CONFIG_SIMP_TO_TRAD;
    }
    SimpleConverter* instance = new SimpleConverter(configFileName);
    return instance;
  OPENCC_C_API_CATCH_END(nullptr)
}

#ifdef _MSC_VER
opencc_t opencc_open_w(const wchar_t* configFileName) {
  OPENCC_C_API_CATCH_BEGIN
    if (configFileName == nullptr) {
      return opencc_open_internal(nullptr);
    }
    std::string utf8fn = UTF8Util::U16ToU8(configFileName);
    return opencc_open_internal(utf8fn.c_str());
  OPENCC_C_API_CATCH_END(nullptr)
}

opencc_t opencc_open(const char* configFileName) {
  if (configFileName == nullptr) {
    return opencc_open_internal(nullptr);
  }
  std::wstring wFileName;
  int convcnt = MultiByteToWideChar(CP_ACP, 0, configFileName, -1, NULL, 0);
  if (convcnt > 0) {
    wFileName.resize(convcnt);
    MultiByteToWideChar(CP_ACP, 0, configFileName, -1, &wFileName[0], convcnt);
  }
  return opencc_open_w(wFileName.c_str());
}
#else
opencc_t opencc_open(const char* configFileName) {
  return opencc_open_internal(configFileName);
}
#endif

int opencc_close(opencc_t opencc) {
  OPENCC_C_API_CATCH_BEGIN
    SimpleConverter* instance = reinterpret_cast<SimpleConverter*>(opencc);
    delete instance;
    return 0;
  OPENCC_C_API_CATCH_END(1)
}

size_t opencc_convert_utf8_to_buffer(opencc_t opencc, const char* input,
                                     size_t length, char* output) {
  OPENCC_C_API_CATCH_BEGIN
    SimpleConverter* instance = reinterpret_cast<SimpleConverter*>(opencc);
    return instance->Convert(input, length, output);
  OPENCC_C_API_CATCH_END(static_cast<size_t>(-1))
}

char* opencc_convert_utf8(opencc_t opencc, const char* input, size_t length) {
  OPENCC_C_API_CATCH_BEGIN
    SimpleConverter* instance = reinterpret_cast<SimpleConverter*>(opencc);
    std::string converted = instance->Convert(input, length);
    char* output = new char[converted.length() + 1];
    memcpy(output, converted.c_str(), converted.length());
    output[converted.length()] = '\0';
    return output;
  OPENCC_C_API_CATCH_END(nullptr)
}

void opencc_convert_utf8_free(char* str) { delete[] str; }

const char* opencc_error(void) { return cError.c_str(); }

namespace {
template <typename Writer>
void WriteInspectionResultJson(Writer& writer,
                               const ConversionInspectionResult& result) {
  writer.StartObject();
  writer.Key("input");
  writer.String(result.input.c_str(), result.input.size());
  writer.Key("output");
  writer.String(result.output.c_str(), result.output.size());
  writer.Key("segments");
  writer.StartArray();
  for (const auto& seg : result.segments) {
    writer.String(seg.c_str(), seg.size());
  }
  writer.EndArray();
  writer.Key("stages");
  writer.StartArray();
  for (const auto& stage : result.stages) {
    writer.StartObject();
    writer.Key("index");
    writer.Uint64(stage.index);
    writer.Key("segments");
    writer.StartArray();
    for (const auto& seg : stage.segments) {
      writer.String(seg.c_str(), seg.size());
    }
    writer.EndArray();
    writer.EndObject();
  }
  writer.EndArray();
  writer.Key("pipelineStages");
  writer.StartArray();
  for (const auto& ps : result.pipelineStages) {
    WriteInspectionResultJson(writer, ps);
  }
  writer.EndArray();
  writer.EndObject();
}
} // namespace

opencc_t opencc_open_with_zip(const char* configFileName,
                     int includeTofuRiskDictionaries,
                     const char* resourceZipPath) {
  OPENCC_C_API_CATCH_BEGIN
    ConfigLoadOptions options;
    options.includeTofuRiskDictionaries =
        (includeTofuRiskDictionaries != 0);

    if (resourceZipPath != nullptr && resourceZipPath[0] != '\0') {
      std::shared_ptr<ResourceProvider> provider(
          new ZipResourceProvider(resourceZipPath));
      return new SimpleConverter(configFileName, provider, options);
    }
    return new SimpleConverter(configFileName, options);
  OPENCC_C_API_CATCH_END(nullptr)
}

char* opencc_inspect_utf8(opencc_t opencc, const char* input, size_t length) {
  OPENCC_C_API_CATCH_BEGIN
    SimpleConverter* instance = reinterpret_cast<SimpleConverter*>(opencc);
    const ConversionInspectionResult result =
        length == static_cast<size_t>(-1)
            ? instance->Inspect(std::string_view(input))
            : instance->Inspect(std::string_view(input, length));

    rapidjson::StringBuffer buffer;
    rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
    WriteInspectionResultJson(writer, result);

    const std::string json = buffer.GetString();
    char* output = new char[json.length() + 1];
    memcpy(output, json.c_str(), json.length());
    output[json.length()] = '\0';
    return output;
  OPENCC_C_API_CATCH_END(nullptr)
}