(defproject squadron "placeholder"
  :description "FIXME: write description"
  :url "http://example.com/FIXME"
  ;; :license {:name "Eclipse Public License"
  ;; :url "http://www.eclipse.org/legal/epl-v10.html"}
  :main squadron.core
  :plugins [[org.clojars.cvillecsteele/lein-git-version "1.0.2"]
            [cider/cider-nrepl "0.8.0"]]
  :dependencies [[org.clojure/clojure "1.6.0"]
                 [clj-logging-config "1.9.12"]
                 [org.clojure/tools.nrepl "0.2.6"]
                 [org.clojure/data.json "0.2.5"]
                 [org.clojure/tools.cli "0.3.1"]
                 [slingshot "0.12.1"]
                 [me.raynes/fs "1.4.6"]])
