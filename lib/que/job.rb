# frozen_string_literal: true

# The class that jobs should inherit from.

module Que
  class Job
    SQL.register_sql_statement \
      :insert_job,
      %{
        INSERT INTO public.que_jobs
        (queue, priority, run_at, job_class, data)
        VALUES
        (
          coalesce($1, '')::text,
          coalesce($2, 100)::smallint,
          coalesce($3, now())::timestamptz,
          $4::text,
          coalesce($5, '{"args":[]}')::jsonb
        )
        RETURNING *
      }

    SQL.register_sql_statement \
      :destroy_job,
      %{
        DELETE FROM public.que_jobs
        WHERE queue    = $1::text
          AND priority = $2::smallint
          AND run_at   = $3::timestamptz
          AND id       = $4::bigint
      }

    attr_reader :que_attrs, :que_error

    def initialize(attrs)
      @que_attrs = attrs
    end

    # Subclasses should define their own run methods, but keep an empty one
    # here so that Que::Job.enqueue can queue an empty job in testing.
    def run(*args)
    end

    def _run
      run(*que_attrs.fetch(:data).fetch(:args))
    rescue => error
      @que_error = error
      run_error_notifier = handle_error(error)

      Que.notify_error(error, que_attrs) if run_error_notifier
    ensure
      destroy unless @que_resolved
    end

    private

    def error_count
      que_attrs.fetch(:error_count)
    end

    def handle_error(error)
      error_count = que_attrs[:error_count] += 1
      delay       = self.class.resolve_setting(:retry_interval, error_count)
      retry_in(delay)
    end

    # Explicitly check for the job id in these helpers, because it won't exist
    # if we're doing JobClass.run().
    def retry_in(period)
      if key = job_key
        Que.execute :set_error, [
          period,
          que_error.message,
          que_error.backtrace.join("\n"),
        ] + job_key
      end

      @que_resolved = true
    end

    def destroy
      if key = job_key
        Que.execute :destroy_job, key
      end

      @que_resolved = true
    end

    def job_key
      key = que_attrs.values_at(:queue, :priority, :run_at, :id)
      key if key.all? { |v| !v.nil? }
    end

    @retry_interval = proc { |count| count ** 4 + 3 }

    class << self
      attr_accessor :run_synchronously

      def enqueue(
        *args,
        queue:     nil,
        priority:  nil,
        run_at:    nil,
        job_class: nil,
        **arg_opts
      )

        args << arg_opts if arg_opts.any?

        attrs = {
          queue:    queue     || resolve_setting(:queue) || Que.default_queue,
          priority: priority  || resolve_setting(:priority),
          run_at:   run_at    || resolve_setting(:run_at),
          data:     Que.serialize_json(args: args),
          job_class: \
            job_class || name ||
            raise(Error, "Can't enqueue an anonymous subclass of Que::Job"),
        }

        if attrs[:run_at].nil? && resolve_setting(:run_synchronously)
          run(*args)
        else
          values =
            Que.execute(
              :insert_job,
              attrs.values_at(:queue, :priority, :run_at, :job_class, :data),
            ).first

          new(values)
        end
      end

      def run(*args)
        # Make sure things behave the same as they would have with a round-trip
        # to the DB.
        args = Que.deserialize_json(Que.serialize_json(args))

        # Should not fail if there's no DB connection.
        new(data: {args: args}).tap { |job| job.run(*args) }
      end

      def resolve_setting(setting, *args)
        iv_name = :"@#{setting}"

        if instance_variable_defined?(iv_name)
          value = instance_variable_get(iv_name)
          value.respond_to?(:call) ? value.call(*args) : value
        else
          c = superclass
          c.resolve_setting(setting, *args) if c.respond_to?(:resolve_setting)
        end
      end
    end
  end
end
