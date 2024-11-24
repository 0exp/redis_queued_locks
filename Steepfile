# frozen_string_literal: true

target :lib do
  signature 'sig'

  check 'lib'
  ignore 'spec'

  library 'timeout'
  library 'securerandom'
  library 'logger'
  library 'objspace'
  library 'monitor'

  configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)
end
