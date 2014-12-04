(ns squadron.core
  (:require
   [clojure.string :refer [split]]
   [clojure.tools.cli :refer [parse-opts]]
   [clojure.java.shell :as shell :refer [sh]]
   [clojure.tools.logging :as log]
   [clojure.data.json :refer [read-str write-str]]
   [slingshot.slingshot :refer [throw+ try+]])
  (:gen-class))

(def base-command "aws --profile promotably-ops ")

(defn create-key
  [region key-name]
  (let [cmd (str base-command "ec2 create-key-pair --output text --region "
                 region " --key-name " key-name)
        {:keys [exit out err] :as result} (apply sh (split cmd #" "))]
    (if (= 0 exit)
      (split out #"\t")
      (throw+ {:type ::create-key-error
               :result result
               :cmd cmd
               :key-name key-name}))))

(defn delete-key
  [region key-name]
  (let [cmd (str base-command "ec2 delete-key-pair --output text --region "
                 region " --key-name " key-name)
        {:keys [exit out err] :as result} (apply sh (split cmd #" "))]
    (if (= 0 exit)
      nil
      (throw+ {:type ::delete-error
               :result result
               :key-name key-name
               :region region}))))

(defn upload-key-to-keyvault
  [key-file-name bucket-name region]
  (let [cmd (str base-command "s3 --region " region
                 " cp " key-file-name " s3://" bucket-name)
        {:keys [exit out err] :as result} (apply sh (split cmd #" "))]
    (if-not (= 0 exit)
      (throw+ {:type ::keyvault-error
               :result result
               :cmd cmd
               :key-file-name key-file-name}))))

(defn cf-create-network
  [{:keys [region
           stack-name bastion-key-bucket
           bastion-key-name nat-key-name
           bastion-instance-type nat-instance-type]
    :as options}]
  (let [cmd (format "%s cloudformation create-stack --output json --region %s --template-body file://resources/network.json --stack-name %s --capabilities CAPABILITY_IAM --parameters ParameterKey=BastionKeyName,ParameterValue=%s ParameterKey=NATKeyName,ParameterValue=%s ParameterKey=BastionInstanceType,ParameterValue=%s ParameterKey=BastionKeyBucket,ParameterValue=%s ParameterKey=NATInstanceType,ParameterValue=%s"
                    base-command
                    region
                    stack-name
                    bastion-key-name
                    nat-key-name
                    bastion-instance-type
                    bastion-key-bucket
                    nat-instance-type)
        {:keys [exit out err] :as result} (apply sh (split cmd #"\s+"))]
    (if (= 0 exit)
      (read-str (:out result) :key-fn (comp keyword clojure.string/lower-case))
      (throw+ {:type ::cf-create-network-error
               :result result
               :cmd cmd}))))

(defn cf-create-api
  [{:keys [region stack-name] :as options}]
  (let [mappings [[:priv-subnets "PrivateSubnets"]
                  [:pub-subnets "PublicSubnets"]
                  [:vpcid "VpcId"]
                  [:availability-zones "AvailabilityZones"]
                  [:github-user "GitHubUser"]
                  [:github-pw "GitHubPW"]
                  [:github-ref "GitHubRef"]
                  [:bastion-sg "BastionSecurityGroup"]
                  [:keypair "KeyPair"]
                  [:nat-sg "NATSecurityGroup"]
                  [:db-name "DBName"]
                  [:db-username "DBUsername"]
                  [:db-password "DBPassword"]
                  [:db-class "DBClass"]
                  [:db-storage "DBAllocatedStorage"]
                  [:db-subnets "DBSubnetIDs"]
                  [:test-results-topic-arn "TestResultsSNSTopicARN"]
                  [:stage "Environment"]
                  [:cache-subnets "CacheSubnetIDs"]]
        cmd (str base-command " "
                 "cloudformation create-stack --output json "
                 "--region " region  " "
                 "--template-body file://resources/api.json "
                 "--stack-name " stack-name " "
                 "--capabilities CAPABILITY_IAM "
                 "--parameters "
                 (apply str (interpose
                             " "
                             (map
                              #(format "ParameterKey=%s,ParameterValue=%s"
                                       (second %)
                                       ((first %) options))
                              mappings))))
        {:keys [exit out err] :as result} (apply sh (split cmd #"\s+"))]
    (if (= 0 exit)
      (read-str (:out result) :key-fn (comp keyword clojure.string/lower-case))
      (throw+ {:type ::cf-create-api-error
               :result result
               :cmd cmd}))))

(defn cf-create-zk
  [{:keys [region stack-name] :as options}]
  (let [mappings [[:priv-subnets "PrivateSubnets"]
                  [:pub-subnets "PublicSubnets"]
                  [:vpcid "VpcId"]
                  [:availability-zones "AvailabilityZones"]
                  [:bastion-sg "BastionSecurityGroup"]
                  [:keypair "KeyName"]
                  [:zk-backup-bucket "ExhibitorS3Bucket"]
                  [:region "ExhibitorS3Region"]
                  [:stack-name "ExhibitorS3Prefix"]]
        cmd (str base-command " "
                 "cloudformation create-stack --output json "
                 "--region " region  " "
                 "--template-body file://resources/zk.json "
                 "--stack-name " stack-name " "
                 "--capabilities CAPABILITY_IAM "
                 "--parameters "
                 (apply str (interpose
                             " "
                             (map
                              #(format "ParameterKey=%s,ParameterValue=%s"
                                       (second %)
                                       ((first %) options))
                              mappings))))
        {:keys [exit out err] :as result} (apply sh (split cmd #"\s+"))]
    (if (= 0 exit)
      (read-str (:out result) :key-fn (comp keyword clojure.string/lower-case))
      (throw+ {:type ::cf-create-api-error
               :result result
               :cmd cmd}))))

(defn cf-create-pagify
  [{:keys [region stack-name] :as options}]
  (let [mappings [[:pub-subnet-id "PublicSubnetId"]
                  [:priv-subnet-id "PrivateSubnetId"]
                  [:vpcid "VpcId"]
                  [:kinesis-stream-a "KinesisStreamA"]
                  [:kinesis-stream-b "KinesisStreamB"]
                  [:github-user "GitHubUser"]
                  [:github-pw "GitHubPW"]
                  [:github-ref "GitHubRef"]
                  [:bastion-sg "BastionSecurityGroup"]
                  [:stage "Environment"]
                  [:keypair "KeyPair"]]
        cmd (str base-command " "
                 "cloudformation create-stack --output json "
                 "--region " region  " "
                 "--template-body file://resources/pagify.json "
                 "--stack-name " stack-name " "
                 "--capabilities CAPABILITY_IAM "
                 "--parameters "
                 (apply str (interpose
                             " "
                             (map
                              #(format "ParameterKey=%s,ParameterValue=%s"
                                       (second %)
                                       ((first %) options))
                              mappings))))
        {:keys [exit out err] :as result} (apply sh (split cmd #"\s+"))]
    (if (= 0 exit)
      (read-str (:out result) :key-fn (comp keyword clojure.string/lower-case))
      (throw+ {:type ::cf-create-pagify-error
               :result result
               :cmd cmd}))))

(defn cf-describe-stack
  [region stack-name]
  (let [cmd (format "%s cloudformation describe-stacks --output json --region %s --stack-name %s"
                    base-command
                    region
                    stack-name)
        {:keys [exit out err] :as result} (apply sh (split cmd #"\s+"))]
    (if (= 0 exit)
      (let [res (-> (read-str (:out result) :key-fn (comp keyword clojure.string/lower-case))
                    :stacks
                    first)
            outputs (reduce
                     #(assoc %1
                        (-> %2 :outputkey clojure.string/lower-case keyword)
                        (:outputvalue %2))
                     {}
                     (-> res :outputs))]
        (assoc res :outputs outputs))
      (throw+ {:type ::cf-describe-stack-error
               :result result
               :cmd cmd}))))

(defn deploy-network
  [region keyname keyvault-bucket-name network-stack-name]
  (let [res (create-key region keyname)]
    (when res
      (spit (str keyname ".pem") (second res))
      (upload-key-to-keyvault (str keyname ".pem") keyvault-bucket-name region)
      (cf-create-network {:region region
                          :stack-name network-stack-name
                          :bastion-key-bucket keyvault-bucket-name
                          :bastion-key-name keyname
                          :nat-key-name keyname
                          :bastion-instance-type "t1.micro"
                          :nat-instance-type "t1.micro"}))))

(defn wait-for-stack-complete
  [region stack-name]
  (loop [result (cf-describe-stack region stack-name)]
    (when (= "CREATE_IN_PROGRESS" (:stackstatus result))
      (Thread/sleep 5000)
      (recur (cf-describe-stack region stack-name)))))

(defn get-random-hex-string
  [how-long]
  (apply str (take how-long (repeatedly #(rand-nth "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")))))

(defn build
  [{:keys [super-stack-name
           stage
           test-results-topic-arn
           keyvault-bucket github-user github-password
           db-username db-name db-password db-instance-type
           pagify-ref api-ref] :as options}]
  (if-not github-password
    (throw+ {:type ::missing-parameter :parameter :github-password}))
  (if-not github-user
    (throw+ {:type ::missing-parameter :parameter :github-user}))
  (let [region "us-east-1"
        super-stack-name (or super-stack-name
                             (str "squadron-" (get-random-hex-string 6)))
        keyname (str super-stack-name "-devops")
        keyvault-bucket-name keyvault-bucket
        network-stack-name (str super-stack-name "-network")
        create-result (deploy-network region
                                      keyname
                                      keyvault-bucket-name
                                      network-stack-name)
        _ (wait-for-stack-complete region network-stack-name)
        description (cf-describe-stack region network-stack-name)
        outputs (:outputs description)
        private-subnets (apply str (concat ["'"]
                                           (interpose ","
                                                      [(:privatesubneta outputs)
                                                       (:privatesubnetb outputs)
                                                       (:privatesubnetc outputs)
                                                       ])
                                           ["'"]))
        api-stack-name (str super-stack-name "-api")
        zk-stack-name (str super-stack-name "-zk")]
    (cf-create-api {:region region
                    :stack-name api-stack-name
                    :bastion-sg (:bastionsecuritygroup outputs)
                    :nat-sg (:natsecuritygroup outputs)
                    :priv-subnets (:privatesubneta outputs)
                    :pub-subnets (:publicsubneta outputs)
                    :github-user github-user
                    :github-pw github-password
                    :github-ref api-ref
                    :keypair keyname
                    :db-name db-name
                    :db-username db-username
                    :db-password db-password
                    :db-class db-instance-type
                    :db-storage 5
                    :db-subnets private-subnets
                    :cache-subnets private-subnets
                    :vpcid (:vpcid outputs)
                    :availability-zones (str region "a")
                    :test-results-topic-arn test-results-topic-arn
                    :stage stage})
    (cf-create-zk {:region region
                   :stack-name zk-stack-name
                   :zk-backup-bucket (:zk-backup-bucket options)
                   :bastion-sg (:bastionsecuritygroup outputs)
                   :priv-subnets (:privatesubneta outputs)
                   :pub-subnets (:publicsubneta outputs)
                   :keypair keyname
                   :vpcid (:vpcid outputs)
                   :availability-zones (str region "a")})
    (wait-for-stack-complete region api-stack-name)
    (let [description (cf-describe-stack region api-stack-name)
          api-outputs (:outputs description)]
      (cf-create-pagify {:region region
                         :stack-name (str super-stack-name "-pagify")
                         :bastion-sg (:bastionsecuritygroup outputs)
                         :pub-subnet-id (:publicsubneta outputs)
                         :priv-subnet-id (:privatesubneta outputs)
                         :github-user github-user
                         :github-pw github-password
                         :github-ref pagify-ref
                         :keypair keyname
                         :kinesis-stream-a (:kinesisstreama api-outputs)
                         :kinesis-stream-b (:kinesisstreamb api-outputs)
                         :vpcid (:vpcid outputs)
                         :stage stage}))))

(def cli-options
  [[nil "--test-results-topic-arn TOPIC-ARN" "Topic ARN for test results notification."
    :default "arn:aws:sns:us-east-1:955631477036:api-integration-tests"]
   [nil "--github-user USER" "Github username"]
   [nil "--github-password PW" "Github password"]
   [nil "--api-ref REF" "Git reference (tag, branch, commit id) for API repo."
    :default "master"]
   [nil "--squadron-ref REF" "Git reference (tag, branch, commit id) for squadron repo."
    :default "master"]
   [nil "--pagify-ref REF" "Git reference (tag, branch, commit id) for pagify repo."
    :default "master"]
   [nil "--keyvault-bucket BUCKET-NAME" "Existing S3 bucket where keys should be stored."
    :default "promotably-keyvault"]
   [nil "--db-name DB-NAME" "Name of database" :default "promotably"]
   [nil "--db-username DB-USERNAME" "Name of database user" :default "promotably"]
   [nil "--db-password DB-PW" "DB user's password" :default "promotably"]
   [nil "--db-instance-type DB-INSTANCE" "DB user's password" :default "db.m1.small"]
   [nil "--super-stack-name SSN" "A name for the stacks on AWS" :default nil]
   [nil "--zk-backup-bucket BUCKETNAME" "A name for zk backup bucket"
    :default "promotably-zk-backups"]
   [nil "--stage ENV" "A name for stage/environment for the squadron"
    :default "integration"]
   ;; A non-idempotent option
   ["-v" nil "Verbosity level"
    :id :verbosity
    :default 0
    :assoc-fn (fn [m k _] (update-in m [k] inc))]
   ;; A boolean option defaulting to nil
   ["-h" "--help"]])

(defn -main
  "stuff"
  [& args]
  (alter-var-root #'base-command (constantly "aws "))
  (let [{:keys [options summary errors] :as parsed} (parse-opts args cli-options)]
    ;; (clojure.pprint/pprint parsed)
    ;; (System/exit 0)
    (build options)
    (shutdown-agents)))
