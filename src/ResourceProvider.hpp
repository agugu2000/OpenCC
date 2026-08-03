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

#pragma once

#include <string>
#include <string_view>
#include <memory>
#include <vector>

#include "Exception.hpp"
#include "Export.hpp"

namespace opencc {

class OPENCC_EXPORT ResourceProvider {
public:
  class OPENCC_EXPORT Resource {
  public:
    Resource(std::string name_, const char* data_, size_t size_,
             std::shared_ptr<const void> owner_, std::string cacheKey_);

    const std::string& Name() const { return name; }
    const char* Data() const { return data; }
    size_t Size() const { return size; }
    const std::string& CacheKey() const { return cacheKey; }

  private:
    std::string name;
    const char* data;
    size_t size;
    std::shared_ptr<const void> owner;
    std::string cacheKey;
  };

  virtual ~ResourceProvider() = default;

  virtual std::string Resolve(std::string_view resourceName) const = 0;

  virtual std::shared_ptr<const Resource>
  GetResource(std::string_view resourceName) const;
};

class OPENCC_EXPORT FilesystemResourceProvider : public ResourceProvider {
public:
  explicit FilesystemResourceProvider(std::vector<std::string> searchPaths);

  std::string Resolve(std::string_view resourceName) const override;

private:
  std::vector<std::string> searchPaths;
};

class OPENCC_EXPORT ZipResourceProvider : public ResourceProvider {
public:
  explicit ZipResourceProvider(std::string zipFileName);
  // ========== OPENCC_MOD: embedded zip (start) ==========
  ZipResourceProvider(const unsigned char* zipData, size_t zipSize);
  // ========== OPENCC_MOD: embedded zip (end) ==========
  ~ZipResourceProvider();

  ZipResourceProvider(const ZipResourceProvider&) = delete;
  ZipResourceProvider& operator=(const ZipResourceProvider&) = delete;

  std::string Resolve(std::string_view resourceName) const override;

  std::shared_ptr<const Resource>
  GetResource(std::string_view resourceName) const override;

private:
  struct Internal;
  std::unique_ptr<Internal> internal;
};

// ========== OPENCC_MOD: embedded assets fallback (start) ==========
class OPENCC_EXPORT ChainedResourceProvider : public ResourceProvider {
public:
  void AddProvider(std::shared_ptr<ResourceProvider> provider) {
    providers_.push_back(std::move(provider));
  }

  std::string Resolve(std::string_view resourceName) const override {
    for (const auto& p : providers_) {
      try { return p->Resolve(resourceName); }
      catch (FileNotFound&) { continue; }
    }
    throw FileNotFound(std::string(resourceName));
  }

  std::shared_ptr<const Resource> GetResource(std::string_view resourceName) const override {
    for (const auto& p : providers_) {
      try { return p->GetResource(resourceName); }
      catch (FileNotFound&) { continue; }
    }
    throw FileNotFound(std::string(resourceName));
  }

private:
  std::vector<std::shared_ptr<ResourceProvider>> providers_;
};
// ========== OPENCC_MOD: embedded assets fallback (end) ==========

} // namespace opencc
