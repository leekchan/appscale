#!/usr/bin/env python
#
# Copyright 2007 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
""" AppScale Search API stub."""

import logging
import os
import string
import tempfile
import threading
import urllib
import uuid

from google.appengine.datastore import document_pb
from google.appengine.api import apiproxy_stub
from google.appengine.api.namespace_manager import namespace_manager
from google.appengine.api.search import query_parser
from google.appengine.api.search import QueryParser
from google.appengine.api.search import search
from google.appengine.api.search import search_service_pb
from google.appengine.api.search import search_util
from google.appengine.api.search.simple_search_stub import SimpleIndex
from google.appengine.ext.remote_api import remote_api_pb                       
from google.appengine.runtime import apiproxy_errors

# Where the SSL certificate is placed for encrypted communication.
CERT_LOCATION = "/etc/appscale/certs/mycert.pem"

# Where the SSL private key is placed for encrypted communication.
KEY_LOCATION = "/etc/appscale/certs/mykey.pem"

class SearchServiceStub(apiproxy_stub.APIProxyStub):
  """ AppScale backed Search service stub.

  This stub provides the search_service_pb.SearchService. But this is
  NOT a subclass of SearchService itself.  Services are provided by
  the methods prefixed by "_Dynamic_".
  """

  _VERSION = 1

  def __init__(self, service_name='search', index_file=None):
    """ Constructor.

    Args:
      service_name: Service name expected for all calls.
      index_file: The file to which search indexes will be persisted.
    """
    self.__indexes = {}
    self.__index_file = index_file
    self.__index_file_lock = threading.Lock()
    super(SearchServiceStub, self).__init__(service_name)

    self.Read()

  def _InvalidRequest(self, status, exception):
    status.set_code(search_service_pb.SearchServiceError.INVALID_REQUEST)
    status.set_error_detail(exception.message)

  def _UnknownIndex(self, status, index_spec):
    status.set_code(search_service_pb.SearchServiceError.OK)
    status.set_error_detail('no index for %r' % index_spec)

  def _GetNamespace(self, namespace):
    """ Get namespace name.

    Args:
      namespace: Namespace provided in request arguments.

    Returns:
      If namespace is None, returns the name of the current global namespace. If
      namespace is not None, returns namespace.
    """
    if namespace is not None:
      return namespace
    return namespace_manager.get_namespace()

  def _GetIndex(self, index_spec, create=False):
    namespace = self._GetNamespace(index_spec.namespace())

    index = self.__indexes.setdefault(namespace, {}).get(index_spec.name())
    if index is None:
      if create:
        index = SimpleIndex(index_spec)
        self.__indexes[namespace][index_spec.name()] = index
      else:
        return None
    return index

  def _Dynamic_IndexDocument(self, request, response):
    """ A local implementation of SearchService.IndexDocument RPC.

    Index a new document or update an existing document.

    Args:
      request: A search_service_pb.IndexDocumentRequest.
      response: An search_service_pb.IndexDocumentResponse.
    """
    self._RemoteSend(request, response, "IndexDocument")

  def _Dynamic_DeleteDocument(self, request, response):
    """ A local implementation of SearchService.DeleteDocument RPC.

    Args:
      request: A search_service_pb.DeleteDocumentRequest.
      response: An search_service_pb.DeleteDocumentResponse.
    """
    self._RemoteSend(request, response, "DeleteDocument")

  def _Dynamic_ListIndexes(self, request, response):
    """ A local implementation of SearchService.ListIndexes RPC.

    Args:
      request: A search_service_pb.ListIndexesRequest.
      response: An search_service_pb.ListIndexesResponse.

    Raises:
      ResponseTooLargeError: raised for testing admin console.
    """
    self._RemoteSend(request, response, "ListIndexes")

  def _Dynamic_ListDocuments(self, request, response):
    """ A local implementation of SearchService.ListDocuments RPC.

    Args:
      request: A search_service_pb.ListDocumentsRequest.
      response: An search_service_pb.ListDocumentsResponse.
    """
    self._RemoteSend(request, response, "ListDocuments")
 
  def _Dynamic_Search(self, request, response):
    """ A local implementation of SearchService.Search RPC.

    Args:
      request: A search_service_pb.SearchRequest.
      response: An search_service_pb.SearchResponse.
    """
    self._RemoteSend(request, response, "Search")

  def __repr__(self):
    return search_util.Repr(self, [('__indexes', self.__indexes)])

  def Write(self):
    """ Write search indexes to the index file.

    This method is a no-op.
    """
    return

  def _ReadFromFile(self):
    self.__index_file_lock.acquire()
    try:
      if os.path.isfile(self.__index_file):
        version, indexes = pickle.load(open(self.__index_file, 'rb'))
        if version == self._VERSION:
          return indexes
        logging.warning(
            'Saved search indexes are not compatible with this version of the '
            'SDK. Search indexes have been cleared.')
      else:
        logging.warning(
            'Could not read search indexes from %s', self.__index_file)
    except (AttributeError, LookupError, ImportError, NameError, TypeError,
            ValueError, pickle.PickleError, IOError), e:
      logging.warning(
          'Could not read indexes from %s. Try running with the '
          '--clear_search_index flag. Cause:\n%r' % (self.__index_file, e))
    finally:
      self.__index_file_lock.release()

    return {}

  def Read(self):
    """ Read search indexes from the index file.

    This method is a no-op if index_file is set to None.
    """
    if not self.__index_file:
      return
    read_indexes = self._ReadFromFile()
    if read_indexes:
      self.__indexes = read_indexes

  def _RemoteSend(self, request, response, method):
    """ Sends a request remotely to the datstore server. """
    api_request = remote_api_pb.Request()
    api_request.set_method(method)
    api_request.set_service_name("search")
    api_request.set_request(request.Encode())

    api_response = remote_api_pb.Response()
    api_response = api_request.sendCommand(self.__datastore_location,
      "",
      api_response,
      1,
      False,
      KEY_LOCATION,
      CERT_LOCATION)

    if not api_response or not api_response.has_response():
      raise datastore_errors.InternalError(
          'No response from db server on %s requests.' % method)

    if api_response.has_application_error():
      error_pb = api_response.application_error()
      logging.error(error_pb.detail())
      raise apiproxy_errors.ApplicationError(error_pb.code(),
                                             error_pb.detail())

    if api_response.has_exception():
      raise api_response.exception()

    response.ParseFromString(api_response.response())
