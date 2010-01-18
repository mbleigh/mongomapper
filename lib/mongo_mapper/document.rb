module MongoMapper
  module Document
    extend DescendantAppends

    def self.included(model)
      model.class_eval do
        include InstanceMethods
        extend  ClassMethods
        extend  Finders

        extend Plugins
        plugin Plugins::Associations
        plugin Plugins::Clone
        plugin Plugins::Descendants
        plugin Plugins::Equality
        plugin Plugins::Inspect
        plugin Plugins::Keys
        plugin Plugins::Dirty # for now dirty needs to be after keys
        plugin Plugins::Logger
        plugin Plugins::Pagination
        plugin Plugins::Rails
        plugin Plugins::Serialization
        plugin Plugins::Validations
        plugin Plugins::Callbacks # for now callbacks needs to be after validations
        
        extend Plugins::Validations::DocumentMacros
      end
      
      super
    end
    
    module ClassMethods
      def inherited(subclass)
        subclass.set_collection_name(collection_name)
        super
      end

      def ensure_index(name_or_array, options={})
        keys_to_index = if name_or_array.is_a?(Array)
          name_or_array.map { |pair| [pair[0], pair[1]] }
        else
          name_or_array
        end

        MongoMapper.ensure_index(self, keys_to_index, options)
      end

      def find!(*args)
        options = args.extract_options!
        case args.first
          when :first then first(options)
          when :last  then last(options)
          when :all   then find_every(options)
          when Array  then find_some(args, options)
          else
            case args.size
              when 0
                raise DocumentNotFound, "Couldn't find without an ID"
              when 1
                find_one!(options.merge({:_id => args[0]}))
              else
                find_some(args, options)
            end
        end
      end
      
      def find(*args)
        find!(*args)
      rescue DocumentNotFound
        nil
      end

      def first(options={})
        find_one(options)
      end

      def last(options={})
        raise ':order option must be provided when using last' if options[:order].blank?
        find_one(options.merge(:order => invert_order_clause(options[:order])))
      end

      def all(options={})
        find_every(options)
      end

      def find_by_id(id)
        find(id)
      end

      def count(options={})
        collection.find(to_criteria(options)).count
      end

      def exists?(options={})
        !count(options).zero?
      end

      def create(*docs)
        initialize_each(*docs) { |doc| doc.save }
      end

      def create!(*docs)
        initialize_each(*docs) { |doc| doc.save! }
      end

      def update(*args)
        if args.length == 1
          update_multiple(args[0])
        else
          id, attributes = args
          update_single(id, attributes)
        end
      end

      def delete(*ids)
        collection.remove(to_criteria(:_id => ids.flatten))
      end

      def delete_all(options={})
        collection.remove(to_criteria(options))
      end

      def destroy(*ids)
        find_some(ids.flatten).each(&:destroy)
      end

      def destroy_all(options={})
        all(options).each(&:destroy)
      end
      
      def increment(*args)
        modifier_update('$inc', args)
      end
      
      def decrement(*args)
        criteria, keys = criteria_and_keys_from_args(args)
        values, to_decrement = keys.values, {}
        keys.keys.each_with_index { |k, i| to_decrement[k] = -values[i].abs }
        collection.update(criteria, {'$inc' => to_decrement}, :multi => true)
      end
      
      def set(*args)
        modifier_update('$set', args)
      end
      
      def push(*args)
        modifier_update('$push', args)
      end
      
      def push_all(*args)
        modifier_update('$pushAll', args)
      end
      
      def push_uniq(*args)
        criteria, keys = criteria_and_keys_from_args(args)
        keys.each { |key, value | criteria[key] = {'$ne' => value} }
        collection.update(criteria, {'$push' => keys}, :multi => true)
      end
      
      def pull(*args)
        modifier_update('$pull', args)
      end
      
      def pull_all(*args)
        modifier_update('$pullAll', args)
      end
      
      def pop(*args)
        modifier_update('$pop', args)
      end
      
      def modifier_update(modifier, args)
        criteria, keys = criteria_and_keys_from_args(args)
        modifiers = {modifier => keys}
        collection.update(criteria, modifiers, :multi => true)
      end
      private :modifier_update
      
      def criteria_and_keys_from_args(args)
        keys     = args.pop
        criteria = args[0].is_a?(Hash) ? args[0] : {:id => args}
        [to_criteria(criteria), keys]
      end
      private :criteria_and_keys_from_args

      def embeddable?
        false
      end

      def connection(mongo_connection=nil)
        if mongo_connection.nil?
          @connection ||= MongoMapper.connection
        else
          @connection = mongo_connection
        end
        @connection
      end

      def set_database_name(name)
        @database_name = name
      end
      
      def database_name
        @database_name
      end

      def database
        if database_name.nil?
          MongoMapper.database
        else
          connection.db(database_name)
        end
      end

      def set_collection_name(name)
        @collection_name = name
      end

      def collection_name
        @collection_name ||= self.to_s.tableize.gsub(/\//, '.')
      end

      def collection
        database.collection(collection_name)
      end

      def timestamps!
        key :created_at, Time
        key :updated_at, Time
        class_eval { before_save :update_timestamps }
      end

      def userstamps!
        key :creator_id, ObjectId
        key :updater_id, ObjectId
        belongs_to :creator, :class_name => 'User'
        belongs_to :updater, :class_name => 'User'
      end

      def single_collection_inherited?
        keys.key?(:_type) && single_collection_inherited_superclass?
      end

      def single_collection_inherited_superclass?
        superclass.respond_to?(:keys) && superclass.keys.key?(:_type)
      end

      private
        def initialize_each(*docs)
          instances = []
          docs = [{}] if docs.blank?
          docs.flatten.each do |attrs|
            doc = new(attrs)
            yield(doc)
            instances << doc
          end
          instances.size == 1 ? instances[0] : instances
        end

        def find_every(options)
          criteria, options = to_finder_options(options)
          collection.find(criteria, options).to_a.map do |doc|
            load(doc)
          end
        end

        def find_some(ids, options={})
          ids       = ids.flatten.compact.uniq
          documents = find_every(options.merge(:_id => ids))

          if ids.size == documents.size
            documents
          else
            raise DocumentNotFound, "Couldn't find all of the ids (#{ids.to_sentence}). Found #{documents.size}, but was expecting #{ids.size}"
          end
        end

        def find_one(options={})
          criteria, options = to_finder_options(options)
          if doc = collection.find_one(criteria, options)
            load(doc)
          end
        end

        def find_one!(options={})
          find_one(options) || raise(DocumentNotFound, "Document match #{options.inspect} does not exist in #{collection.name} collection")
        end

        def invert_order_clause(order)
          order.split(',').map do |order_segment|
            if order_segment =~ /\sasc/i
              order_segment.sub /\sasc/i, ' desc'
            elsif order_segment =~ /\sdesc/i
              order_segment.sub /\sdesc/i, ' asc'
            else
              "#{order_segment.strip} desc"
            end
          end.join(',')
        end

        def update_single(id, attrs)
          if id.blank? || attrs.blank? || !attrs.is_a?(Hash)
            raise ArgumentError, "Updating a single document requires an id and a hash of attributes"
          end

          doc = find(id)
          doc.update_attributes(attrs)
          doc
        end

        def update_multiple(docs)
          unless docs.is_a?(Hash)
            raise ArgumentError, "Updating multiple documents takes 1 argument and it must be hash"
          end

          instances = []
          docs.each_pair { |id, attrs| instances << update(id, attrs) }
          instances
        end

        def to_criteria(options={})
          FinderOptions.new(self, options).criteria
        end

        def to_finder_options(options={})
          FinderOptions.new(self, options).to_a
        end
    end

    module InstanceMethods
      def collection
        self.class.collection
      end

      def database
        self.class.database
      end

      def save(options={})
        options.reverse_merge!(:validate => true)
        perform_validations = options.delete(:validate)
        !perform_validations || valid? ? create_or_update(options) : false
      end

      def save!
        save || raise(DocumentNotValid.new(self))
      end
      
      def update_attributes(attrs={})
        self.attributes = attrs
        save
      end

      def update_attributes!(attrs={})
        self.attributes = attrs
        save!
      end

      def destroy
        delete
      end
      
      def delete
        self.class.delete(id) unless new?
      end

      def reload
        if attrs = collection.find_one({:_id => _id})
          self.class.associations.each { |name, assoc| send(name).reset if respond_to?(name) }
          self.attributes = attrs
          self
        else
          raise DocumentNotFound, "Document match #{_id.inspect} does not exist in #{collection.name} collection"
        end
      end

    private
      def create_or_update(options={})
        result = new? ? create(options) : update(options)
        result != false
      end

      def create(options={})
        save_to_collection(options)
      end

      def update(options={})
        save_to_collection(options)
      end

      def save_to_collection(options={})
        safe = options.delete(:safe) || false
        @new = false
        collection.save(to_mongo, :safe => safe)
      end

      def update_timestamps
        now = Time.now.utc
        self[:created_at] = now if new? && !created_at?
        self[:updated_at] = now
      end
    end
  end # Document
end # MongoMapper
