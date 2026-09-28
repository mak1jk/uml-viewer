(ns uml-viewer.cpp-language.clang-uml-spec
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [speclj.core :refer :all]
            [uml-viewer.cpp-language.clang-uml :as clang-uml]
            [uml-viewer.cpp-language.source-cpp]
            [uml-viewer.application.detail :as detail]
            [uml-viewer.application.document :as document]
            [uml-viewer.domain.hierarchy :as hierarchy]
            [uml-viewer.source :as source]))

(defn- extracted-json []
  (with-open [r (io/reader (io/resource "resources/cpp-fixture.json"))]
    (json/read r :key-fn keyword)))

(defn- fixture-document []
  (clang-uml/convert (extracted-json) "examples/cpp-fixture"))

(describe "clang-uml adapter"
  (it "preserves namespace-qualified class identity and exact relationships"
    (let [doc (fixture-document)
          by-id (into {} (map (juxt :id identity) (:classes doc)))
          edge-pairs (set (map (juxt :from :to :kind) (:edges doc)))]
      (should= 3 (count (:classes doc)))
      (should= "model::Node" (:qualified-name (by-id :model.Node)))
      (should= "store::Node" (:qualified-name (by-id :store.Node)))
      (should-not= (:clang-uml-id (by-id :model.Node))
                   (:clang-uml-id (by-id :store.Node)))
      (should (contains? edge-pairs [:app.Controller :model.Node :inheritance]))
      (should (contains? edge-pairs [:app.Controller :store.Node :dependency]))))

  (it "keeps overloads distinct and points classes and methods to exact source lines"
    (let [doc (fixture-document)
          view (hierarchy/view-at doc [:app])
          controller (first (filter #(= :app.Controller (:id %))
                                    (mapcat :classes (:packages view))))
          overloads (filter #(= "run" (:name %)) (:ops controller))
          class-location (:source-ident controller)]
      (should= "include/app/controller.hpp" (:file class-location))
      (should= 7 (:line class-location))
      (should= 2 (count overloads))
      (should= [9 10] (mapv #(get-in % [:source-ident :line]) overloads))
      (should-not= (get-in (first overloads) [:source-ident :overload-id])
                   (get-in (second overloads) [:source-ident :overload-id]))
      (should= ["int value" "double value"] (mapv :signature overloads))))

  (it "opens the source file at the clang-uml line without parsing C++"
    (let [doc (fixture-document)
          method-ident (-> (hierarchy/view-at doc [:app])
                           :packages first :classes first :ops first :source-ident)
          opened (source/member-source :cpp method-ident)
          target-line (nth (clojure.string/split (:body opened) #"\r?\n")
                           (dec (:line opened)))]
      (should= 9 (:line opened))
      (should= 7 (:column opened))
      (should (.contains target-line "run(int value)"))))

  (it "exposes class and overloaded-method locations in navigable detail rows"
    (let [doc (fixture-document)
          scene (document/compile-view doc "target/cpp-no-metrics" [:app])
          rows (detail/rows (detail/model scene :app.Controller))
          class-row (first (filter #(= :name (:kind %)) rows))
          overload-rows (filter #(= "run" (:op-name %)) rows)
          metric-note (first (filter #(= "Metrics unavailable for this C++ diagram"
                                         (:text %)) rows))]
      (should= 7 (get-in (detail/source-at rows (:y class-row)) [:line]))
      (should= [9 10] (mapv #(get-in (detail/source-at rows (:y %)) [:line]) overload-rows))
      (should metric-note))))
